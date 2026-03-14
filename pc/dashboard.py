import os, requests, pyperclip, threading, uvicorn, shutil, socket, time, tempfile, webbrowser, subprocess
import sys
from fastapi import FastAPI, Request, UploadFile, File
from fastapi.responses import FileResponse, Response
from tkinter import filedialog, messagebox
import tkinter as tk
import tkinter.ttk as ttk
import tkinter.font as tkfont
from typing import Any, Optional

app = FastAPI()
clipboard_history = []
_upload_progress: dict = {"filename": "", "received": 0, "total": 0, "done": False}

#  SETUP
SHARE_FOLDER = os.path.join(os.path.expanduser("~"), "Downloads", "FastSync")
os.makedirs(SHARE_FOLDER, exist_ok=True)

IMAGE_EXTS  = {'.jpg', '.jpeg', '.png', '.gif', '.webp', '.bmp'}
VIDEO_EXTS  = {'.mp4', '.mkv', '.mov', '.avi', '.wmv'}
AUDIO_EXTS  = {'.mp3', '.wav', '.m4a', '.flac', '.ogg'}
PDF_EXTS    = {'.pdf'}
MIME_MAP = {
    '.jpg':'image/jpeg', '.jpeg':'image/jpeg', '.png':'image/png',
    '.gif':'image/gif',  '.webp':'image/webp', '.bmp':'image/bmp',
    '.pdf':'application/pdf',
    '.mp4':'video/mp4',  '.mkv':'video/x-matroska',
    '.mov':'video/quicktime', '.avi':'video/x-msvideo',
    '.mp3':'audio/mpeg', '.wav':'audio/wav', '.m4a':'audio/mp4',
    '.txt':'text/plain',
}


def get_local_ip() -> str:
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("8.8.8.8", 80))
        ip = s.getsockname()[0]
        s.close()
        return ip
    except Exception:
        return "127.0.0.1"


MY_IP = get_local_ip()
ui_app: Optional["FastSyncUI"] = None

#  AUTO-DISCOVERY: UDP BROADCAST  PC → Phone
def udp_broadcast():
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
    while True:
        try:
            sock.sendto(f"FASTSYNC_PC:{MY_IP}".encode(), ("<broadcast>", 9876))
        except Exception:
            pass
        time.sleep(2)



#  AUTO-DISCOVERY: UDP LISTENER  Phone → PC
def listen_for_phone():
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind(("", 9877))
    while True:
        try:
            data, addr = sock.recvfrom(1024)
            msg = data.decode()
            if msg.startswith("FASTSYNC_PHONE:"):
                phone_ip = addr[0]  # use actual sender IP
                instance = ui_app
                if instance is not None:
                    instance.root.after(
                        0, lambda ip=phone_ip, u=instance: u.set_phone_ip(ip)
                    )
        except Exception:
            pass

#  FASTAPI BACKEND  (port 8000)


@app.post("/from_phone")
async def receive_phone_clip(req: Request):
    data = await req.json()
    text = data.get("text", "").strip()
    if text:
        pyperclip.copy(text)
        if text not in clipboard_history:
            clipboard_history.append(text)
            if len(clipboard_history) > 20:
                clipboard_history.pop(0)
        instance = ui_app
        if instance is not None:
            instance.last_clipboard = text
            instance.root.after(0, instance.update_clip_display)
            instance.root.after(0, lambda t=text, u=instance: u.notify(f"📋 Received clipboard from phone"))
    return {"status": "ok"}


@app.post("/upload_to_pc")
async def upload_to_pc(request: Request, filename: str = ""):
    """Streaming receive with progress tracking."""
    global _upload_progress
    if not filename:
        # fallback: try multipart
        ct = request.headers.get("content-type", "")
        if "multipart" in ct:
            from fastapi import UploadFile
            form = await request.form()
            file_obj = list(form.values())[0]
            filename = getattr(file_obj, "filename", None) or "uploaded_file"
            save_path = os.path.join(SHARE_FOLDER, filename)
            with open(save_path, "wb") as f:
                if hasattr(file_obj, "file"):
                    shutil.copyfileobj(file_obj.file, f)
                elif isinstance(file_obj, str):
                    f.write(file_obj.encode())
                else:
                    raise TypeError("Uploaded object is not a file-like object")
            instance = ui_app
            if instance is not None:
                instance.root.after(0, lambda fn=filename, u=instance: u.notify(f"📥 File received: {fn}"))
            return {"status": "saved"}
        filename = "uploaded_file"

    save_path = os.path.join(SHARE_FOLDER, filename)
    total = int(request.headers.get("content-length", 0))
    _upload_progress = {"filename": filename, "received": 0, "total": total, "done": False}

    instance = ui_app
    if instance is not None:
        instance.root.after(0, lambda: instance.show_receive_progress(filename, total))

    with open(save_path, "wb") as f:
        async for chunk in request.stream():
            f.write(chunk)
            _upload_progress["received"] += len(chunk)

    _upload_progress["done"] = True
    if instance is not None:
        instance.root.after(0, lambda fn=filename, u=instance: u.notify(f"📥 File received: {fn}"))
    return {"status": "saved"}


@app.get("/get_history")
def get_history():
    return clipboard_history


@app.get("/pc_list")
def list_pc_files(path: str = "DRIVES"):
    if path == "DRIVES":
        return [
            {"name": f"{d}:\\", "isDir": True}
            for d in "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
            if os.path.exists(f"{d}:\\")
        ]
    try:
        items = []
        for entry in os.listdir(path):
            full = os.path.join(path, entry)
            items.append({"name": full, "isDir": os.path.isdir(full)})
        return sorted(items, key=lambda x: (not x["isDir"], x["name"].lower()))
    except Exception:
        return []


@app.get("/download_file")
async def download_file(path: str):
    if os.path.exists(path) and os.path.isfile(path):
        ext = os.path.splitext(path)[1].lower()
        mime = MIME_MAP.get(ext, "application/octet-stream")
        
        # inline for everything previewable, attachment only for unknowns
        inline_exts = IMAGE_EXTS | VIDEO_EXTS | AUDIO_EXTS | PDF_EXTS
        disposition = "inline" if ext in inline_exts else "attachment"
        
        return FileResponse(
            path,
            media_type=mime,
            headers={
                "Content-Disposition": f'{disposition}; filename="{os.path.basename(path)}"',
                "Accept-Ranges": "bytes",   # ← enables seeking in video/audio
            }
        )
    return Response(content="Not found", status_code=404)


#  TKINTER UI

class FastSyncUI:
    def __init__(self, root: tk.Tk) -> None:
        self.root = root
        self.root.title("FastSync")
        self.root.geometry("1150x740")
        self.root.configure(bg="#0f172a")
        self.root.minsize(850, 620)

        import sys
        icon_path = os.path.join(getattr(sys, '_MEIPASS', os.path.dirname(__file__)), 'assets', 'icon.ico')
        if os.path.exists(icon_path):
            try:
                self.root.iconbitmap(icon_path)
            except Exception:
                pass


        self.current_path: str = ""
        self.path_stack: list = []
        self.phone_ip_var = tk.StringVar()
        self.last_clipboard: str = pyperclip.paste()

        # declared for IDE
        self.status_var: tk.StringVar
        self.conn_label: tk.Label
        self.listbox: tk.Listbox
        self.path_var: tk.StringVar
        # canvas-based clip panel refs
        self.clip_canvas: tk.Canvas
        self.clip_inner: tk.Frame
        self._clip_row_widgets: list = []

        self._build_ui()
        self.root.after(300, self.check_clipboard)  

    def _build_ui(self) -> None:

        # ── Premium ttk styles ──
        style = ttk.Style()
        style.theme_use("clam")
        style.configure("Nav.TButton",
                        background="#334155", foreground="white",
                        font=("Segoe UI Semibold", 10),
                        borderwidth=0, focusthickness=0,
                        padding=(0, 9))  # Reduced x-padding so all 3 fit
        style.map("Nav.TButton",
                  background=[("active", "#475569"), ("pressed", "#1e293b")])

        style.configure("Accent.TButton",
                        background="#3b82f6", foreground="white",
                        font=("Segoe UI Semibold", 11),
                        borderwidth=0, focusthickness=0,
                        padding=(12, 11))
        style.map("Accent.TButton",
                  background=[("active", "#2563eb"), ("pressed", "#1d4ed8")])

        style.configure("Side.TButton",
                        background="#334155", foreground="white",
                        font=("Segoe UI Semibold", 11),
                        borderwidth=0, focusthickness=0,
                        padding=(12, 11))
        style.map("Side.TButton",
                  background=[("active", "#475569"), ("pressed", "#1e293b")])

        style.configure("Copy.TButton",
                        background="#0ea5e9", foreground="white",
                        font=("Segoe UI Semibold", 9),
                        borderwidth=0, focusthickness=0,
                        padding=(9, 5))
        style.map("Copy.TButton",
                  background=[("active", "#0284c7"), ("pressed", "#0369a1")])

        style.configure("TProgressbar",
                        troughcolor="#1e293b",
                        background="#3b82f6",
                        borderwidth=0,
                        thickness=8)

        # Nav Bar 
        nav = tk.Frame(self.root, bg="#1e293b", height=52)
        nav.pack(side="top", fill="x")
        nav.pack_propagate(False)

        # Nav buttons frame matching sidebar width (280px)
        nav_btn_frame = tk.Frame(nav, bg="#1e293b", width=280)
        nav_btn_frame.pack(side="left", fill="y")
        nav_btn_frame.pack_propagate(False)

        ttk.Button(nav_btn_frame, text="Home", command=self.go_home,
                   style="Nav.TButton", cursor="hand2", width=0
                   ).pack(side="left", fill="both", expand=True, padx=(10, 2), pady=8)
        ttk.Button(nav_btn_frame, text="Back", command=self.go_back,
                   style="Nav.TButton", cursor="hand2", width=0
                   ).pack(side="left", fill="both", expand=True, padx=2, pady=8)
        ttk.Button(nav_btn_frame, text="Refresh", command=self.load_phone_files,
                   style="Nav.TButton", cursor="hand2", width=0
                   ).pack(side="left", fill="both", expand=True, padx=(2, 10), pady=8)
        
        self.status_var = tk.StringVar(
            value=f"PC IP: {MY_IP}   |    Phone: waiting...")
        tk.Label(nav, textvariable=self.status_var,
                 fg="#38bdf8", bg="#1e293b",
                 font=("Segoe UI Semibold", 10)).pack(side="right", padx=18)


        # Main Layout
        main = tk.Frame(self.root, bg="#0f172a")
        main.pack(fill="both", expand=True)

        # Sidebar 
        side = tk.Frame(main, bg="#1e293b", width=280)
        side.pack(side="left", fill="y")
        side.pack_propagate(False)

        tk.Label(side, text="FastSync", fg="#38bdf8", bg="#1e293b",
                 font=("Segoe UI", 19, "bold")).pack(pady=(24, 3))
        tk.Label(side, text="Your PC's IP Address",
                 fg="#94a3b8", bg="#1e293b",
                 font=("Segoe UI Semibold", 10)).pack()
        tk.Label(side, text=MY_IP, fg="#22c55e", bg="#1e293b",
                 font=("Segoe UI", 17, "bold")).pack(pady=(4, 16))

        tk.Frame(side, bg="#334155", height=1).pack(fill="x", padx=20)

        tk.Label(side, text=" Phone IP", fg="#94a3b8", bg="#1e293b",
                 font=("Segoe UI Semibold", 10)).pack(pady=(12, 3))
        phone_entry = tk.Entry(side, textvariable=self.phone_ip_var,
                               bg="#0f172a", fg="white",
                               insertbackground="white", borderwidth=0,
                               highlightthickness=2, highlightcolor="#38bdf8",
                               highlightbackground="#334155",
                               font=("Segoe UI Semibold", 13))
        phone_entry.pack(pady=3, padx=18, fill="x", ipady=8)
        phone_entry.bind("<Return>", lambda _: self.load_phone_files())

        self.conn_label = tk.Label(side, text="⏳ Waiting for phone...",
                                    fg="#f59e0b", bg="#1e293b",
                                    font=("Segoe UI Semibold", 10))
        self.conn_label.pack(pady=6)

        tk.Frame(side, bg="#334155", height=1).pack(fill="x", padx=20)

        #  Modern Clipboard Panel
        clip_header = tk.Frame(side, bg="#1e293b")       
        clip_header.pack(fill="x", padx=12, pady=(12, 2))
        tk.Label(clip_header, text="📋  Clipboard History",
                 fg="#22c55e", bg="#1e293b",
                 font=("Segoe UI Semibold", 11, "bold")).pack(side="left")
        tk.Button(clip_header, text="✕ Clear", command=self._clear_clipboard,
                  bg="#1e293b", fg="#ef4444", bd=0, highlightthickness=0,
                  relief="flat", font=("Segoe UI Semibold", 9, "bold"),
                  cursor="hand2", padx=6, activebackground="#1e293b",
                  activeforeground="#f87171"
                  ).pack(side="right", pady=2)

        clip_wrap = tk.Frame(side, bg="#0f172a", bd=0)
        clip_wrap.pack(fill="x", padx=12, pady=(0, 4))
        self._build_clip_panel(clip_wrap)

        # Sidebar Buttons 
        ttk.Button(side, text="📤  Send File to Phone",
                   command=self.send_file_to_phone,
                   style="Accent.TButton", cursor="hand2"
                   ).pack(pady=(12, 5), padx=18, fill="x")
        ttk.Button(side, text="📁  Open FastSync Folder",
                   command=lambda: os.startfile(SHARE_FOLDER),
                   style="Side.TButton", cursor="hand2"
                   ).pack(pady=5, padx=18, fill="x")

        #Right: File Browser
        right = tk.Frame(main, bg="#0f172a")
        right.pack(side="right", fill="both", expand=True)

        self.path_var = tk.StringVar(value=" Phone / ")
        tk.Label(right, textvariable=self.path_var,
                 fg="#94a3b8", bg="#0f172a",
                 font=("Segoe UI Semibold", 10), anchor="w"
                 ).pack(fill="x", padx=18, pady=(12, 3))

        list_frame = tk.Frame(right, bg="#1e293b", bd=0,
                             highlightthickness=1, highlightbackground="#334155")
        list_frame.pack(fill="both", expand=True, padx=18, pady=(0, 18))

        list_scroll = tk.Scrollbar(list_frame, bg="#1e293b",
                                   troughcolor="#0f172a", bd=0,
                                   highlightthickness=0, relief="flat")
        list_scroll.pack(side="right", fill="y")

        self.listbox = tk.Listbox(
            list_frame, bg="#0f172a", fg="#e2e8f0",
            font=("Segoe UI Semibold", 12), borderwidth=0,
            highlightthickness=0, relief="flat",
            selectbackground="#1e3a5f", activestyle="none",
            yscrollcommand=list_scroll.set)
        self.listbox.pack(side="left", fill="both", expand=True)
        list_scroll.config(command=self.listbox.yview)
        self.listbox.bind("<Double-Button-1>", self._on_item_double_click)
        self.listbox.bind("<Button-3>", self._on_right_click)   # right-click menu


    #   MODERN CLIPBOARD PANEL


    def _build_clip_panel(self, parent: tk.Frame) -> None:
        container = tk.Frame(parent, bg="#0f172a", height=200)
        container.pack(fill="x")
        container.pack_propagate(False)

        scroll = tk.Scrollbar(container, orient="vertical", bg="#1e293b",
                               troughcolor="#0f172a", bd=0,
                               highlightthickness=0, relief="flat")
        scroll.pack(side="right", fill="y")

        self.clip_canvas = tk.Canvas(container, bg="#0f172a",
                                      highlightthickness=0,
                                      yscrollcommand=scroll.set)
        self.clip_canvas.pack(side="left", fill="both", expand=True)
        scroll.config(command=self.clip_canvas.yview)

        self.clip_inner = tk.Frame(self.clip_canvas, bg="#0f172a")
        self._clip_win = self.clip_canvas.create_window(
            (0, 0), window=self.clip_inner, anchor="nw")

        self.clip_inner.bind(
            "<Configure>",
            lambda e: self.clip_canvas.configure(
                scrollregion=self.clip_canvas.bbox("all")))
        self.clip_canvas.bind(
            "<Configure>",
            lambda e: self.clip_canvas.itemconfig(
                self._clip_win, width=e.width))
        # Mouse wheel scroll
        self.clip_canvas.bind("<MouseWheel>",
            lambda e: self.clip_canvas.yview_scroll(-1 * (e.delta // 120), "units"))

    def update_clip_display(self) -> None:
        """Rebuild the canvas clip cards."""
        for w in self.clip_inner.winfo_children():
            w.destroy()

        items = list(reversed(clipboard_history))
        font_main = ("Segoe UI Semibold", 10)
        font_btn  = ("Segoe UI Semibold", 9, "bold")

        for idx, text in enumerate(items):
            # Card frame
            card = tk.Frame(self.clip_inner, bg="#1e293b",
                            highlightthickness=1,
                            highlightbackground="#334155")
            card.pack(fill="x", padx=4, pady=(3, 0))

            # Preview label (left)
            preview = text[:28].replace("\n", " ") + ("…" if len(text) > 28 else "")
            lbl = tk.Label(card, text=preview, bg="#1e293b",
                           fg="#e2e8f0", font=font_main,
                           anchor="w", padx=8)
            lbl.pack(side="left", fill="x", expand=True, pady=6)

            # Copy button (right)
            real_idx = len(clipboard_history) - 1 - idx

            def _copy(i=real_idx):
                if 0 <= i < len(clipboard_history):
                    pyperclip.copy(clipboard_history[i])
                    self.notify("📋 Copied!")

            copy_btn = tk.Button(
                card, text="⎘ Copy", command=_copy,
                bg="#0ea5e9", fg="white", font=font_btn,
                bd=0, highlightthickness=0, relief="flat",
                padx=9, pady=4, cursor="hand2",
                activebackground="#0284c7", activeforeground="white")
            copy_btn.pack(side="right", padx=5, pady=5)

            # Hover effect
            for w in (card, lbl):
                w.bind("<Enter>", lambda e, c=card: c.configure(bg="#243447",
                    highlightbackground="#38bdf8"))
                w.bind("<Leave>", lambda e, c=card: c.configure(bg="#1e293b",
                    highlightbackground="#334155"))
                lbl.bind("<Enter>", lambda e, c=card: c.configure(bg="#243447"))

    def _clear_clipboard(self) -> None:
        """Clear all clipboard history on PC side."""
        clipboard_history.clear()
        self.update_clip_display()
        self.notify("🗑️ Clipboard cleared")


    #  AUTO-DISCOVERY CALLBACK

    def set_phone_ip(self, ip: str) -> None:
        if self.phone_ip_var.get() == ip:
            return
        self.phone_ip_var.set(ip)
        self.conn_label.config(text=f"✅ Auto-found: {ip}", fg="#22c55e")
        self.status_var.set(f"💻 PC IP: {MY_IP}   |   📱 Phone: {ip} ✅")
        self.load_phone_files()

    #  LOAD PHONE FILES

    def load_phone_files(self) -> None:
        self.listbox.delete(0, tk.END)
        ip = self.phone_ip_var.get().strip()
        if not ip:
            self.listbox.insert(tk.END, "⏳  Waiting for phone...")
            return
        try:
            res = requests.get(
                f"http://{ip}:9000/list?path={self.current_path}", timeout=3)
            items = res.json()
            dp = self.current_path if self.current_path else "/"
            self.path_var.set(f"📱 Phone / {dp}")
            for item in items:
                icon = "📁" if item["isDir"] else self._file_icon(item["name"])
                self.listbox.insert(tk.END, f"  {icon}  {item['name']}")
            self.conn_label.config(text=f"✅ Connected: {ip}", fg="#22c55e")
            self.status_var.set(f"💻 PC IP: {MY_IP}   |   📱 Phone: {ip} ✅")
        except Exception:
            self.listbox.insert(tk.END, "⚠️  Phone offline or unreachable")
            self.conn_label.config(text="❌ Phone Unreachable", fg="#ef4444")

    def _file_icon(self, name: str) -> str:
        ext = os.path.splitext(name)[1].lower()
        if ext in IMAGE_EXTS: return "🖼️"
        if ext in VIDEO_EXTS: return "🎬"
        if ext in AUDIO_EXTS: return "🎵"
        if ext in PDF_EXTS:   return "📕"
        if ext in {'.zip','.rar','.7z'}: return "🗜️"
        if ext in {'.doc','.docx'}:      return "📝"
        return "📄"

    #  DOUBLE-CLICK: navigate or preview/download
    def _on_item_double_click(self, event: tk.Event) -> None:
        sel = self.listbox.curselection()
        if not sel:
            return
        raw  = self.listbox.get(sel[0]).strip()
        name = raw.split("  ", 2)[-1].strip()   # strip icon + spaces
        ip   = self.phone_ip_var.get().strip()
        if not ip:
            return

        # check if it's a folder entry 
        is_folder = "📁" in raw

        if is_folder:
            self.path_stack.append(self.current_path)
            self.current_path = (
                os.path.join(self.current_path, name) if self.current_path else name)
            self.load_phone_files()
        else:
            full_path = f"/storage/emulated/0/{self.current_path}/{name}".replace("//", "/")
            self._preview_or_download_phone_file(ip, name, full_path)

    def _on_right_click(self, event: tk.Event) -> None:
        """Right-click context menu on file list."""
        idx = self.listbox.nearest(event.y)
        if idx < 0:
            return
        self.listbox.selection_clear(0, tk.END)
        self.listbox.selection_set(idx)
        raw  = self.listbox.get(idx).strip()
        name = raw.split("  ", 2)[-1].strip()
        ip   = self.phone_ip_var.get().strip()
        if not ip or "📁" in raw:
            return

        full_path = f"/storage/emulated/0/{self.current_path}/{name}".replace("//", "/")
        menu = tk.Menu(self.root, tearoff=0, bg="#1e293b", fg="white",
                       font=("Segoe UI Semibold", 11), bd=0,
                       activebackground="#334155",
                       activeforeground="#38bdf8")
        menu.add_command(label="👁  Preview",
                         command=lambda: self._preview_or_download_phone_file(
                             ip, name, full_path, force_preview=True))
        menu.add_command(label="⬇  Download",
                         command=lambda: self._download_phone_file(ip, name, full_path))
        menu.post(event.x_root, event.y_root)

    # PREVIEW PHONE FILEs
    def _preview_or_download_phone_file(
            self, ip: str, name: str, full_path: str,
            force_preview: bool = False) -> None:
        ext = os.path.splitext(name)[1].lower()

        if ext in IMAGE_EXTS:
            self._preview_image_from_phone(ip, name, full_path)
        elif ext in PDF_EXTS | VIDEO_EXTS | AUDIO_EXTS:
            # Download to temp then open with system default app
            self._open_phone_file_in_app(ip, name, full_path)
        else:
            self._download_phone_file(ip, name, full_path)

    def _preview_image_from_phone(self, ip: str, name: str, full_path: str) -> None:
        """Show phone image in a Tk popup using PIL."""
        try:
            from PIL import Image, ImageTk
        except ImportError:
            messagebox.showwarning(
                "Pillow missing",
                "Install Pillow to preview images:\n  pip install Pillow\n\nDownloading instead.")
            self._download_phone_file(ip, name, full_path)
            return

        from urllib.parse import quote
        url = f"http://{ip}:9000/download?path={quote(full_path)}"
        try:
            import io as io_mod
            res = requests.get(url, timeout=15)
            img = Image.open(io_mod.BytesIO(res.content))

            # Resize to fit — compatible with all Pillow versions
            resample = getattr(getattr(Image, "Resampling", Image), "LANCZOS", 1)
            img.thumbnail((900, 700), resample) 
            photo = ImageTk.PhotoImage(img)
            

            win = tk.Toplevel(self.root)
            win.title(name)
            win.configure(bg="#0f172a")
            win.resizable(True, True)

            # Toolbar
            bar = tk.Frame(win, bg="#1e293b")
            bar.pack(fill="x")
            tk.Label(bar, text=name, fg="white", bg="#1e293b",
                     font=("Segoe UI Semibold", 11)).pack(side="left", padx=12, pady=8)
            tk.Button(bar, text="⬇ Download", bg="#0ea5e9", fg="white",
                      bd=0, highlightthickness=0, relief="flat",
                      padx=10, pady=5, cursor="hand2",
                      font=("Segoe UI Semibold", 10),
                      activebackground="#0284c7", activeforeground="white",
                      command=lambda: self._download_phone_file(ip, name, full_path)
                      ).pack(side="right", padx=10, pady=6)

            lbl: Any = tk.Label(win, image=photo, bg="#0f172a")
            lbl.image = photo  
            lbl.pack(padx=10, pady=10)

        except Exception as e:
            messagebox.showerror("Preview failed", str(e))

    def _open_phone_file_in_app(self, ip: str, name: str, full_path: str) -> None:
        """Download to temp dir and open with system default app."""
        from urllib.parse import quote
        url = f"http://{ip}:9000/download?path={quote(full_path)}"
        try:
            res = requests.get(url, timeout=30)
            ext = os.path.splitext(name)[1]
            tmp = tempfile.NamedTemporaryFile(delete=False, suffix=ext,
                                              prefix="fastsync_")
            tmp.write(res.content)
            tmp.close()
            os.startfile(tmp.name)  
        except Exception as e:
            messagebox.showerror("Open failed", str(e))

    def _download_phone_file(self, ip: str, name: str, full_path: str) -> None:
        """Save phone file to FastSync folder."""
        from urllib.parse import quote
        url = f"http://{ip}:9000/download?path={quote(full_path)}"
        try:
            res = requests.get(url, timeout=30, stream=True)
            save_path = os.path.join(SHARE_FOLDER, name)
            with open(save_path, "wb") as f:
                for chunk in res.iter_content(8192):
                    f.write(chunk)
            messagebox.showinfo("Downloaded ✅", f"Saved to:\n{save_path}")
        except Exception as e:
            messagebox.showerror("Download failed", str(e))

    def go_home(self) -> None:
        self.current_path = ""
        self.path_stack.clear()
        self.load_phone_files()

    def go_back(self) -> None:
        if self.path_stack:
            self.current_path = self.path_stack.pop()
            self.load_phone_files()

    #  CLIPBOARD 300ms POLLING
    def check_clipboard(self) -> None:
        try:
            current = pyperclip.paste()
            if current and current != self.last_clipboard:
                self.last_clipboard = current
                ip = self.phone_ip_var.get().strip()
                if ip:
                    try:
                        requests.post(f"http://{ip}:9000/clipboard",
                                      json={"text": current}, timeout=1)
                    except Exception:
                        pass
                if current not in clipboard_history:
                    clipboard_history.append(current)
                    if len(clipboard_history) > 20:
                        clipboard_history.pop(0)
                    self.update_clip_display()
        except Exception:
            pass
        self.root.after(300, self.check_clipboard) 

    #  FILE TRANSFER  PC → Phone
    def send_file_to_phone(self) -> None:
        ip = self.phone_ip_var.get().strip()
        if not ip:
            messagebox.showwarning("No Phone", "Phone not connected yet.")
            return
        path = filedialog.askopenfilename(title="Select file to send to phone")
        if not path:
            return

        name  = os.path.basename(path)
        total = os.path.getsize(path)

        # Progress window
        pw = tk.Toplevel(self.root)
        pw.title(f"Sending {name}")
        pw.geometry("420x130")
        pw.configure(bg="#0f172a")
        pw.resizable(False, False)
        tk.Label(pw, text=f"📤  {name}", fg="white", bg="#0f172a",
                 font=("Segoe UI Semibold", 11, "bold")).pack(pady=(18, 5), padx=18, anchor="w")
        prog_var = tk.DoubleVar(value=0)
        ttk.Progressbar(pw, variable=prog_var, maximum=100,
                        length=380).pack(padx=22)
        prog_lbl = tk.Label(pw, text="Connecting…", fg="#94a3b8", bg="#0f172a",
                            font=("Segoe UI Semibold", 10))
        prog_lbl.pack(pady=8)
        pw_alive = [True]
        def _safe_destroy():
            if pw_alive[0]:
                pw_alive[0] = False
                pw.destroy()

        def _do_send():
            try:
                url = f"http://{ip}:9000/upload?name={name}"
                total_mb = total / 1_048_576
                sent     = 0
                CHUNK    = 65536

                with open(path, "rb") as fh:
                    # Open a persistent connection and stream raw bytes
                    import http.client, urllib.parse
                    parsed = urllib.parse.urlparse(url)
                    conn   = http.client.HTTPConnection(parsed.hostname or "localhost", parsed.port or 9000, timeout=120)
                    conn.putrequest("POST", parsed.path + "?" + parsed.query)
                    conn.putheader("Content-Length", str(total))
                    conn.putheader("Content-Type", "application/octet-stream")
                    conn.endheaders()

                    while True:
                        chunk = fh.read(CHUNK)
                        if not chunk:
                            break
                        conn.send(chunk)
                        sent += len(chunk)
                        pct     = sent / total * 100
                        sent_mb = sent / 1_048_576
                        def _upd(p=pct, s=sent_mb, t=total_mb):
                            if pw_alive[0]:
                                prog_var.set(p)
                                prog_lbl.config(text=f"{s:.1f} MB / {t:.1f} MB  ({p:.0f}%)")
                        self.root.after(0, _upd)

                    resp = conn.getresponse()
                    resp.read()
                    conn.close()

                def _done():
                    _safe_destroy()
                    messagebox.showinfo("Sent ✅", "File sent to phone Downloads!")
                self.root.after(0, _done)

            except Exception as e:
                err = str(e)
                def _fail():
                    _safe_destroy()
                    messagebox.showerror("Send Failed", err)
                self.root.after(0, _fail)

        threading.Thread(target=_do_send, daemon=True).start()

    #  RECEIVE PROGRESS
    def show_receive_progress(self, filename: str, total: int) -> None:
        pw = tk.Toplevel(self.root)
        pw.title(f"Receiving {filename}")
        pw.geometry("420x130")
        pw.configure(bg="#0f172a")
        pw.resizable(False, False)
        tk.Label(pw, text=f"📥  {filename}", fg="white", bg="#0f172a",
                 font=("Segoe UI Semibold", 11, "bold")).pack(pady=(18, 5), padx=18, anchor="w")
        pv = tk.DoubleVar(value=0)
        ttk.Progressbar(pw, variable=pv, maximum=100, length=380).pack(padx=22)
        pl = tk.Label(pw, text="Receiving…", fg="#94a3b8", bg="#0f172a",
                      font=("Segoe UI Semibold", 10))
        pl.pack(pady=8)
        total_mb = total / 1_048_576 if total else 0

        def _poll():
            p = _upload_progress
            if p["done"]:
                pv.set(100)
                pl.config(text="Done!")
                self.root.after(800, pw.destroy)
                return
            if total > 0:
                recv = p["received"]
                pct  = recv / total * 100
                pv.set(pct)
                pl.config(text=f"{recv/1_048_576:.1f} MB / {total_mb:.1f} MB  ({pct:.0f}%)")
            self.root.after(200, _poll)
        self.root.after(200, _poll)

    #  NOTIFY — flash status bar
    def notify(self, msg: str) -> None:
        self.status_var.set(msg)
        ph = self.phone_ip_var.get()
        self.root.after(3000, lambda: self.status_var.set(
            f"💻 PC IP: {MY_IP}   |   📱 Phone: {ph or 'waiting...'}"))

#  ENTRY POINT

if __name__ == "__main__":
    import multiprocessing
    multiprocessing.freeze_support()

    if sys.stdout is None:
        sys.stdout = open(os.devnull, "w")
    if sys.stderr is None:
        sys.stderr = open(os.devnull, "w")

    start_in_tray = "--tray" in sys.argv

    threading.Thread(
        target=lambda: uvicorn.run(app, host="0.0.0.0", port=8000,
                                   log_level="error"),
        daemon=True).start()
    threading.Thread(target=udp_broadcast,    daemon=True).start()
    threading.Thread(target=listen_for_phone, daemon=True).start()

    root = tk.Tk()
    ui_app = FastSyncUI(root)

    # System Tray setup FIRST before hiding
    import pystray
    from PIL import Image, ImageDraw

    def _make_tray_icon() -> Image.Image:
        icon_path = os.path.join(getattr(sys, '_MEIPASS', os.path.dirname(__file__)), 'assets', 'icon.ico')
        if os.path.exists(icon_path):
            try:
                return Image.open(icon_path)
            except Exception:
                pass
        img = Image.new("RGBA", (64, 64), (0, 0, 0, 0))
        d = ImageDraw.Draw(img)
        d.ellipse([4, 4, 60, 60], fill="#38bdf8")
        d.ellipse([20, 20, 44, 44], fill="#0f172a")
        return img

    def _show_window(icon, item):
        root.after(0, lambda: root.deiconify())

    def _quit_app(icon, item):
        icon.stop()
        root.after(0, lambda: root.destroy())

    tray = pystray.Icon(
        "FastSync",
        _make_tray_icon(),
        "FastSync — Running",
        menu=pystray.Menu(
            pystray.MenuItem("Show FastSync", _show_window, default=True),
            pystray.MenuItem("Quit", _quit_app),
        )
    )

    root.protocol("WM_DELETE_WINDOW", lambda: root.withdraw())

    # If starting in tray mode, hide window BEFORE mainloop to prevent flash
    if start_in_tray:
        root.withdraw()

    threading.Thread(target=tray.run, daemon=True).start()
    root.mainloop()
    tray.stop() 