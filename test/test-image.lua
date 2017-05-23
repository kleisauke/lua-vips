local vips = require "vips"

local im = vips.operation.call("black", 100, 200, {bands = 3})

print("")
print("get height:")
local height = im:height()
print("height = ", height)

status, err = pcall(
    function()
        x = vips.image.frank(1, 2, 3)
    end
)
if not status then
    print("frank failed with:")
    print(err)
end

image2 = im:invert()

image3 = vips.image.black(1, 2, {bands = 3})

image4 = vips.image.new_from_file("images/Gugg_coloured.jpg")
image4 = image4:invert()
image4:write_to_file("x.jpg")

x = image4:linear({1, 2, 3}, {4, 5, 6})

v = image4:max()
print("max value =", v)

v, x, y, outs, xes, yes = image4:max{size = 10}
print("max value =", v)
print("x =", x)
print("y =", y)
print("outs =", outs)
print("xes =", outs)
print("yes =", outs)

image1 = image4 + image4
image1 = image4 + 12
image4 = vips.image.new_from_file("images/Gugg_coloured.jpg")
image1 = image4 + {40, 0, -12}

image1:write_to_file("x.jpg")
