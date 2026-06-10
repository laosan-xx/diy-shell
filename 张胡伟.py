import os
import re
import glob
import time
import sys
import io
from PIL import Image
from rapidocr import RapidOCR

sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8', errors='replace')

WORK_DIR = r"d:\Users\huYang\Desktop\新建文件夹"
OUTPUT_DIR = os.path.join(WORK_DIR, "output")
A4_W, A4_H = 2480, 3508
GRID_COLS, GRID_ROWS = 2, 2
MARGIN = 20
GAP = 10

GAS_KEYWORDS = ["加油", "汽油", "柴油", "燃油", "中石化", "中石油", "加油站", "石化", "92#", "95#", "98#", "燃料", "油站", "壳牌", "乙醇", "加油费", "油费"]
PARK_KEYWORDS = ["停车", "停车场", "停车费", "车位", "泊车", "泊车费", "停车票", "占道停车", "路边停车", "停车场费", "临时停车", "停车助手", "重庆高科"]

ocr = RapidOCR()


def get_image_time(filepath):
    name = os.path.basename(filepath)
    match = re.search(r'(\d{14})', name)
    if match:
        return match.group(1)
    try:
        from PIL.ExifTags import Base as ExifBase
        img = Image.open(filepath)
        exif = img.getexif()
        if exif:
            dt = exif.get(ExifBase.DateTimeOriginal) or exif.get(ExifBase.DateTime)
            if dt:
                return re.sub(r'[^\d]', '', dt)
    except Exception:
        pass
    mtime = os.path.getmtime(filepath)
    return time.strftime('%Y%m%d%H%M%S', time.localtime(mtime))


def extract_pay_time(full_text):
    match = re.search(r'支付时间\s*(\d{4})[年/\-](\d{1,2})[月/\-](\d{1,2})[日]?\s*(\d{1,2})[时:](\d{1,2})[分:]?(\d{1,2})?', full_text)
    if match:
        y, m, d, h, mi, s = match.groups()
        s = s or '00'
        return f"{y}{m.zfill(2)}{d.zfill(2)}{h.zfill(2)}{mi.zfill(2)}{s.zfill(2)}"
    return ""


def classify_image(filepath):
    try:
        result = ocr(filepath)
        if result.txts:
            full_text = " ".join(result.txts)
            pay_time = extract_pay_time(full_text)
            for kw in PARK_KEYWORDS:
                if kw in full_text:
                    return "停车", full_text, pay_time
            for kw in GAS_KEYWORDS:
                if kw in full_text:
                    return "加油", full_text, pay_time
        return "未知", " ".join(result.txts) if result.txts else "", ""
    except Exception as e:
        print(f"  处理失败: {filepath} - {e}")
        return "未知", "", ""


def make_a4_page(images, page_num, category):
    canvas = Image.new("RGB", (A4_W, A4_H), "white")
    cell_w = (A4_W - 2 * MARGIN - (GRID_COLS - 1) * GAP) // GRID_COLS
    cell_h = (A4_H - 2 * MARGIN - (GRID_ROWS - 1) * GAP) // GRID_ROWS

    for idx, img_path in enumerate(images):
        if idx >= GRID_COLS * GRID_ROWS:
            break
        row = idx // GRID_COLS
        col = idx % GRID_COLS
        x = MARGIN + col * (cell_w + GAP)
        y = MARGIN + row * (cell_h + GAP)

        img = Image.open(img_path)
        img_w, img_h = img.size
        scale = min(cell_w / img_w, cell_h / img_h)
        new_w = int(img_w * scale)
        new_h = int(img_h * scale)
        img_resized = img.resize((new_w, new_h), Image.LANCZOS)

        paste_x = x + (cell_w - new_w) // 2
        paste_y = y + (cell_h - new_h) // 2
        canvas.paste(img_resized, (paste_x, paste_y))

    label = f"{category}_第{page_num}页"
    out_path = os.path.join(OUTPUT_DIR, f"{label}.jpg")
    canvas.save(out_path, "JPEG", quality=95)
    print(f"  已生成: {out_path}")
    return out_path


def main():
    os.makedirs(OUTPUT_DIR, exist_ok=True)

    exts = ("*.jpg", "*.jpeg", "*.png", "*.bmp", "*.webp")
    image_files = []
    for ext in exts:
        image_files.extend(glob.glob(os.path.join(WORK_DIR, ext)))
    image_files = [f for f in image_files if os.path.basename(f) != os.path.basename(__file__)]
    image_files = [f for f in image_files if "output" not in f]
    image_files.sort()
    print(f"找到 {len(image_files)} 张图片\n")

    classified = {"加油": [], "停车": [], "未知": []}
    for i, f in enumerate(image_files, 1):
        name = os.path.basename(f)
        print(f"[{i}/{len(image_files)}] 识别: {name}")
        cat, text, pay_time = classify_image(f)
        if not pay_time:
            pay_time = get_image_time(f)
        classified[cat].append({"path": f, "pay_time": pay_time, "text": text})
        snippet = text[:80] if text else "(无文字)"
        print(f"  -> {cat} | 支付时间:{pay_time} | 文字:{snippet}\n")

    for cat in ["加油", "停车", "未知"]:
        classified[cat].sort(key=lambda x: x["pay_time"])

    print("=" * 60)
    print("分类结果汇总 (按支付时间排序):")
    print("=" * 60)
    for cat in ["加油", "停车", "未知"]:
        print(f"  {cat}: {len(classified[cat])} 张")
        for item in classified[cat]:
            print(f"    {os.path.basename(item['path'])} - 支付时间:{item['pay_time']}")

    print("\n" + "=" * 60)
    print("开始合成A4图片 (每4张一页)...")
    print("=" * 60)
    results = {}
    for cat in ["加油", "停车"]:
        items = classified[cat]
        if not items:
            print(f"  {cat}类无图片，跳过")
            continue
        pages = []
        for i in range(0, len(items), GRID_COLS * GRID_ROWS):
            batch = items[i:i + GRID_COLS * GRID_ROWS]
            page_num = i // (GRID_COLS * GRID_ROWS) + 1
            paths = [b["path"] for b in batch]
            page_path = make_a4_page(paths, page_num, cat)
            pages.append(page_path)
        results[cat] = pages

    if classified["未知"]:
        print(f"\n[!] 有 {len(classified['未知'])} 张图片无法自动分类:")
        for item in classified["未知"]:
            print(f"  {os.path.basename(item['path'])}")

    print("\n" + "=" * 60)
    print(f"完成! 输出目录: {OUTPUT_DIR}")
    print("=" * 60)


if __name__ == "__main__":
    main()