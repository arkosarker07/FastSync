from PIL import Image
import sys

def check_ico(path):
    try:
        img = Image.open(path)
        sizes = []
        if getattr(img, "n_frames", 1) > 1:
            for i in range(img.n_frames):
                img.seek(i)
                sizes.append(img.size)
            print(f"ICO contains {img.n_frames} frames:")
            print(", ".join([f"{s[0]}x{s[1]}" for s in sizes]))
        else:
            print(f"Single image of size: {img.size}")
            
        print("Format:", img.format)
    except Exception as e:
        print("Error:", e)

if __name__ == "__main__":
    check_ico(sys.argv[1])
