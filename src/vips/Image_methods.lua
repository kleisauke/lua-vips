-- an Image class with overloads

local ffi = require "ffi"

local verror = require "vips/verror"
local version = require "vips/version"
local gvalue = require "vips/gvalue"
local vobject = require "vips/vobject"
local voperation = require "vips/voperation"
local Image = require "vips/Image"

local type = type
local error = error
local pairs = pairs
local ipairs = ipairs
local unpack = unpack
local setmetatable = setmetatable
local getmetatable = getmetatable

local vips_lib
local gobject_lib
local glib_lib
if ffi.os == "Windows" then
    vips_lib = ffi.load("libvips-42.dll")
    gobject_lib = ffi.load("libgobject-2.0-0.dll")
    glib_lib = ffi.load("libglib-2.0-0.dll")
else
    vips_lib = ffi.load("vips")
    gobject_lib = vips_lib
    glib_lib = vips_lib
end

ffi.cdef [[
    const char* vips_foreign_find_load (const char* name);
    const char* vips_foreign_find_load_buffer (const void* data, size_t size);
    const char* vips_foreign_find_save (const char* name);
    const char* vips_foreign_find_save_buffer (const char* suffix);

    VipsImage* vips_image_new_matrix_from_array (int width, int height,
            const double* array, int size);

    VipsImage* vips_image_new_from_memory (const void *data, size_t size,
            int width, int height, int bands, int format);
    unsigned char* vips_image_write_to_memory (VipsImage* image,
            size_t* size_out);

    VipsImage* vips_image_copy_memory (VipsImage* image);

    GType vips_image_get_typeof (const VipsImage* image,
        const char* name);
    int vips_image_get (const VipsImage* image,
        const char* name, GValue* value_copy);
    void vips_image_set (VipsImage* image, const char* name, GValue* value);
    int vips_image_remove (VipsImage* image, const char* name);

    char* vips_filename_get_filename (const char* vips_filename);
    char* vips_filename_get_options (const char* vips_filename);

]]

-- test for rectangular array of something
local function is_2D(table)
    if type(table) ~= "table" then
        return false
    end

    for i = 1, #table do
        if type(table[i]) ~= "table" then
            return false
        end
        if #table[i] ~= #table[1] then
            return false
        end
    end

    return true
end

local function map(fn, array)
    local new_array = {}

    for i, v in ipairs(array) do
        new_array[i] = fn(v)
    end

    return new_array
end

local function swap_Image_left(left, right)
    if Image.is_Image(left) then
        return left, right
    elseif Image.is_Image(right) then
        return right, left
    else
        error("must have one image argument")
    end
end

-- either a single number, or a table of numbers
local function is_pixel(value)
    return type(value) == "number" or
            (type(value) == "table" and not Image.is_Image(value))
end

local function call_enum(image, other, base, operation)
    if type(other) == "number" then
        return image[base .. "_const"](image, operation, { other })
    elseif is_pixel(other) then
        return image[base .. "_const"](image, operation, other)
    else
        return image[base](image, other, operation)
    end
end

-- turn a string from libvips that must be g_free()d into a lua string
local function to_string_copy(vips_string)
    local lua_string = ffi.string(vips_string)
    glib_lib.g_free(vips_string)
    return lua_string
end

-- class methods

function Image.is_Image(thing)
    return type(thing) == "table" and getmetatable(thing) == Image.mt
end

function Image.imageize(self, value)
    -- careful! self can be nil if value is a 2D array
    if Image.is_Image(value) then
        return value
    elseif is_2D(value) then
        return Image.new_from_array(value)
    else
        return self:new_from_image(value)
    end
end

-- constructors

-- we add an unref finalizer too! be careful
function Image.new(vimage)
    local image = {}

    vobject.new(vimage)
    image.vimage = vimage

    return setmetatable(image, Image.mt)
end

function Image.find_load(filename)
    local name = vips_lib.vips_foreign_find_load(filename)
    if name == nil then
        return nil
    else
        return ffi.string(name)
    end
end

function Image.new_from_file(vips_filename, ...)
    local filename =
        to_string_copy(vips_lib.vips_filename_get_filename(vips_filename))
    local options =
        to_string_copy(vips_lib.vips_filename_get_options(vips_filename))

    local name = Image.find_load(filename)
    if name == nil then
        error(verror.get())
    end

    return voperation.call(name, options, filename, unpack { ... })
end

function Image.find_load_buffer(data)
    local name = vips_lib.vips_foreign_find_load_buffer(data, #data)
    if name == nil then
        return nil
    else
        return ffi.string(name)
    end
end

function Image.new_from_buffer(data, options, ...)
    local name = Image.find_load_buffer(data)
    if name == nil then
        error(verror.get())
    end

    return voperation.call(name, options or "", data, unpack { ... })
end

function Image.new_from_memory(data, width, height, bands, format)
    local format_value = gvalue.to_enum(gvalue.band_format_type, format)
    local size = ffi.sizeof(data)

    local vimage = vips_lib.vips_image_new_from_memory(data, size,
        width, height, bands, format_value)
    if vimage == nil then
        error(verror.get())
    end

    local image = Image.new(vimage)

    -- libvips is using the memory we passed in: save a pointer to the memory
    -- block to try to stop it being GCd
    image._data = data

    return image
end

function Image.new_from_array(array, scale, offset)
    local width
    local height

    if not is_2D(array) then
        array = { array }
    end
    width = #array[1]
    height = #array

    local n = width * height
    local a = ffi.new(gvalue.pdouble_typeof, n)
    for y = 0, height - 1 do
        for x = 0, width - 1 do
            a[x + y * width] = array[y + 1][x + 1]
        end
    end
    local vimage = vips_lib.vips_image_new_matrix_from_array(width,
        height, a, n)
    local image = Image.new(vimage)

    image:set_type(gvalue.gdouble_type, "scale", scale or 1)
    image:set_type(gvalue.gdouble_type, "offset", offset or 0)

    return image
end

function Image.new_from_image(base_image, value)
    local pixel = (Image.black(1, 1) + value):cast(base_image:format())
    local image = pixel:embed(0, 0, base_image:width(), base_image:height(),
        { extend = "copy" })
    image = image:copy {
        interpretation = base_image:interpretation(),
        xres = base_image:xres(),
        yres = base_image:yres(),
        xoffset = base_image:xoffset(),
        yoffset = base_image:yoffset()
    }

    return image
end

-- this is for undefined class methods, like Image.text
function Image.__index(_, name)
    return function(...)
        return voperation.call(name, "", unpack { ... })
    end
end

-- overloads

function Image.mt.__add(a, b)
    a, b = swap_Image_left(a, b)

    if type(b) == "number" then
        return a:linear({ 1 }, { b })
    elseif is_pixel(b) then
        return a:linear({ 1 }, b)
    else
        return a:add(b)
    end
end

function Image.mt.__sub(a, b)
    if Image.is_Image(a) then
        if type(b) == "number" then
            return a:linear({ 1 }, { -b })
        elseif is_pixel(b) then
            return a:linear({ 1 }, map(function(x) return -x end, b))
        else
            return a:subtract(b)
        end
    else
        -- therefore a is a constant and b is an image
        if type(a) == "number" then
            return (b * -1):linear({ 1 }, { a })
        else
            -- assume a is a pixel
            return (b * -1):linear({ 1 }, a)
        end
    end
end

function Image.mt.__mul(a, b)
    a, b = swap_Image_left(a, b)

    if type(b) == "number" then
        return a:linear({ b }, { 0 })
    elseif is_pixel(b) then
        return a:linear(b, { 0 })
    else
        return a:multiply(b)
    end
end

function Image.mt.__div(a, b)
    if Image.is_Image(a) then
        if type(b) == "number" then
            return a:linear({ 1 / b }, { 0 })
        elseif is_pixel(b) then
            return a:linear(map(function(x) return x ^ -1 end, b), { 0 })
        else
            return a:divide(b)
        end
    else
        -- therefore a is a constant and b is an image
        if type(a) == "number" then
            return (b ^ -1):linear({ a }, { 0 })
        else
            -- assume a is a pixel
            return (b ^ -1):linear(a, { 0 })
        end
    end
end

function Image.mt.__mod(a, b)
    if not Image.is_Image(a) then
        error("constant % image not supported by libvips")
    end

    if type(b) == "number" then
        return a:remainder_const({ b })
    elseif is_pixel(b) then
        return a:remainder_const(b)
    else
        return a:remainder(b)
    end
end

function Image.mt.__unm(self)
    return self * -1
end

function Image.mt.__pow(a, b)
    if Image.is_Image(a) then
        return a:pow(b)
    else
        return b:wop(a)
    end
end

-- unfortunately, lua does not let you return non-bools from <, >, <=, >=, ==,
-- ~=, so there's no point overloading these ... call :more(2) etc. instead

function Image.mt.__tostring(self)
    local result = (self:filename() or "(nil)") .. ": " ..
            self:width() .. "x" .. self:height() .. " " ..
            self:format() .. ", " ..
            self:bands() .. " bands, " ..
            self:interpretation()

    if self:get_typeof("vips-loader") ~= 0 then
        result = result .. ", " .. self:get("vips-loader")
    end

    return result
end

function Image.mt.__call(self, x, y)
    -- getpoint() will return a table for a pixel
    return unpack(self:getpoint(x, y))
end

function Image.mt.__concat(self, other)
    return self:bandjoin(other)
end

local instance_methods = {
    -- utility methods

    vobject = function(self)
        return ffi.cast(vobject.typeof, self.vimage)
    end,

    -- handy to have as instance methods too

    imageize = function(self, value)
        return Image.imageize(self, value)
    end,

    new_from_image = function(self, value)
        return Image.new_from_image(self, value)
    end,

    copy_memory = function(self)
        local vimage = vips_lib.vips_image_copy_memory(self.vimage)
        if vimage == nil then
            error(verror.get())
        end
        return Image.new(vimage)
    end,

    -- writers

    write_to_file = function(self, vips_filename, ...)
        local filename =
            to_string_copy(vips_lib.vips_filename_get_filename(vips_filename))
        local options =
            to_string_copy(vips_lib.vips_filename_get_options(vips_filename))
        local name = vips_lib.vips_foreign_find_save(filename)
        if name == nil then
            error(verror.get())
        end

        return voperation.call(ffi.string(name), options,
            self, filename, unpack { ... })
    end,

    write_to_buffer = function(self, format_string, ...)
        local options =
            to_string_copy(vips_lib.vips_filename_get_options(format_string))
        local name = vips_lib.vips_foreign_find_save_buffer(format_string)
        if name == nil then
            error(verror.get())
        end

        return voperation.call(ffi.string(name), options, self, unpack { ... })
    end,

    write_to_memory = function(self)
        local psize = ffi.new(gvalue.psize_typeof, 1)
        local vips_memory = vips_lib.vips_image_write_to_memory(self.vimage,
            psize)
        local size = psize[0]
        -- FIXME can we avoid the copy somehow?
        local lua_memory = ffi.new(gvalue.mem_typeof, size)
        ffi.copy(lua_memory, vips_memory, size)
        glib_lib.g_free(vips_memory)

        return lua_memory
    end,

    -- get/set metadata

    get_typeof = function(self, name)
        -- on libvips 8.4 and earlier, we need to fetch the type via
        -- our superclass get_typeof(), since vips_image_get_typeof() returned
        -- enum properties as ints
        if not version.at_least(8, 5) then
            local gtype = self:vobject():get_typeof(name)
            if gtype ~= 0 then
                return gtype
            end

            -- we must clear the error buffer after vobject typeof fails
            verror.get()
        end

        return vips_lib.vips_image_get_typeof(self.vimage, name)
    end,

    get = function(self, name)
        -- on libvips 8.4 and earlier, we need to fetch gobject properties via
        -- our superclass get(), since vips_image_get() returned enum properties
        -- as ints
        if not version.at_least(8, 5) then
            local vo = self:vobject()
            local gtype = vo:get_typeof(name)
            if gtype ~= 0 then
                return vo:get(name)
            end

            -- we must clear the error buffer after vobject typeof fails
            verror.get()
        end

        local pgv = gvalue.newp()

        local result = vips_lib.vips_image_get(self.vimage, name, pgv)
        if result ~= 0 then
            error("unable to get " .. name)
        end

        result = pgv[0]:get()

        gobject_lib.g_value_unset(pgv[0])

        return result
    end,

    set_type = function(self, gtype, name, value)
        local gv = gvalue.new()
        gv:init(gtype)
        gv:set(value)
        vips_lib.vips_image_set(self.vimage, name, gv)
    end,

    set = function(self, name, value)
        local gtype = self:get_typeof(name)
        self:set_type(gtype, name, value)
    end,

    remove = function(self, name)
        return vips_lib.vips_image_remove(self.vimage, name) ~= 0
    end,

    -- standard header fields

    width = function(self)
        return self:get("width")
    end,

    height = function(self)
        return self:get("height")
    end,

    size = function(self)
        return self:width(), self:height()
    end,

    bands = function(self)
        return self:get("bands")
    end,

    format = function(self)
        return self:get("format")
    end,

    interpretation = function(self)
        return self:get("interpretation")
    end,

    xres = function(self)
        return self:get("xres")
    end,

    yres = function(self)
        return self:get("yres")
    end,

    xoffset = function(self)
        return self:get("xoffset")
    end,

    yoffset = function(self)
        return self:get("yoffset")
    end,

    filename = function(self)
        return self:get("filename")
    end,

    -- many-image input operations
    --
    -- these don't wrap well automatically, since self is held separately

    bandjoin = function(self, other, options)
        -- allow a single untable arg as well
        if type(other) == "number" or Image.is_Image(other) then
            other = { other }
        end

        -- if other is all constants, we can use bandjoin_const
        local all_constant = true
        for i = 1, #other do
            if type(other[i]) ~= "number" then
                all_constant = false
                break
            end
        end

        if all_constant then
            return voperation.call("bandjoin_const", "", self, other, options)
        else
            return voperation.call("bandjoin", "", { self, unpack(other) }, options)
        end
    end,

    bandrank = function(self, other, options)
        if type(other) ~= "table" then
            other = { other }
        end

        return voperation.call("bandrank", "", { self, unpack(other) }, options)
    end,

    composite = function(self, other, mode, options)
        -- allow a single untable arg as well
        if type(other) == "number" or Image.is_Image(other) then
            other = { other }
        end
        if type(mode) ~= "table" then
            mode = { mode }
        end

        -- need to map str -> int by hand, since the mode arg is actually
        -- arrayint
        for i = 1, #mode do
            mode[i] = gvalue.to_enum(gvalue.blend_mode_type, mode[i])
        end

        return voperation.call("composite", "",
            { self, unpack(other) }, mode, options)
    end,

    -- convenience functions

    bandsplit = function(self)
        local result

        result = {}
        for i = 0, self:bands() - 1 do
            result[i + 1] = self:extract_band(i)
        end

        return result
    end,

    -- special behaviour wrappers

    ifthenelse = function(self, then_value, else_value, options)
        -- We need different imageize rules for this. We need then_value
        -- and else_value to match each other first, and only if they
        -- are both constants do we match to self.

        local match_image

        for _, v in pairs({ then_value, else_value, self }) do
            if Image.is_Image(v) then
                match_image = v
                break
            end
        end

        if not Image.is_Image(then_value) then
            then_value = match_image:imageize(then_value)
        end

        if not Image.is_Image(else_value) then
            else_value = match_image:imageize(else_value)
        end

        return voperation.call("ifthenelse", "",
            self, then_value, else_value, options)
    end,

    -- enum expansions

    pow = function(self, other)
        return call_enum(self, other, "math2", "pow")
    end,

    wop = function(self, other)
        return call_enum(self, other, "math2", "wop")
    end,

    lshift = function(self, other)
        return call_enum(self, other, "boolean", "lshift")
    end,

    rshift = function(self, other)
        return call_enum(self, other, "boolean", "rshift")
    end,

    andimage = function(self, other)
        return call_enum(self, other, "boolean", "and")
    end,

    orimage = function(self, other)
        return call_enum(self, other, "boolean", "or")
    end,

    eorimage = function(self, other)
        return call_enum(self, other, "boolean", "eor")
    end,

    less = function(self, other)
        return call_enum(self, other, "relational", "less")
    end,

    lesseq = function(self, other)
        return call_enum(self, other, "relational", "lesseq")
    end,

    more = function(self, other)
        return call_enum(self, other, "relational", "more")
    end,

    moreeq = function(self, other)
        return call_enum(self, other, "relational", "moreeq")
    end,

    equal = function(self, other)
        return call_enum(self, other, "relational", "equal")
    end,

    noteq = function(self, other)
        return call_enum(self, other, "relational", "noteq")
    end,

    floor = function(self)
        return self:round("floor")
    end,

    ceil = function(self)
        return self:round("ceil")
    end,

    rint = function(self)
        return self:round("rint")
    end,

    bandand = function(self)
        return self:bandbool("and")
    end,

    bandor = function(self)
        return self:bandbool("or")
    end,

    bandeor = function(self)
        return self:bandbool("eor")
    end,

    real = function(self)
        return self:complexget("real")
    end,

    imag = function(self)
        return self:complexget("imag")
    end,

    polar = function(self)
        return self:complex("polar")
    end,

    rect = function(self)
        return self:complex("rect")
    end,

    conj = function(self)
        return self:complex("conj")
    end,

    sin = function(self)
        return self:math("sin")
    end,

    cos = function(self)
        return self:math("cos")
    end,

    tan = function(self)
        return self:math("tan")
    end,

    asin = function(self)
        return self:math("asin")
    end,

    acos = function(self)
        return self:math("acos")
    end,

    atan = function(self)
        return self:math("atan")
    end,

    exp = function(self)
        return self:math("exp")
    end,

    exp10 = function(self)
        return self:math("exp10")
    end,

    log = function(self)
        return self:math("log")
    end,

    log10 = function(self)
        return self:math("log10")
    end,

    erode = function(self, mask)
        return self:morph(mask, "erode")
    end,

    dilate = function(self, mask)
        return self:morph(mask, "dilate")
    end,

    fliphor = function(self)
        return self:flip("horizontal")
    end,

    flipver = function(self)
        return self:flip("vertical")
    end,

    rot90 = function(self)
        return self:rot("d90")
    end,

    rot180 = function(self)
        return self:rot("d180")
    end,

    rot270 = function(self)
        return self:rot("d270")
    end
}

function Image.mt.__index(_, index)
    if instance_methods[index] then
        return instance_methods[index]
    else
        return function(...)
            return voperation.call(index, "", unpack { ... })
        end
    end
end

return Image
