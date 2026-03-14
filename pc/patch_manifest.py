# save as patch_manifest.py in C:\Arko\Easyshare\pc\
import subprocess, os

manifest = """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<assembly xmlns="urn:schemas-microsoft-com:asm.v1" manifestVersion="1.0">
  <trustInfo xmlns="urn:schemas-microsoft-com:asm.v3">
    <security>
      <requestedPrivileges>
        <requestedExecutionLevel level="asInvoker" uiAccess="false"/>
      </requestedPrivileges>
    </security>
  </trustInfo>
</assembly>"""

with open("temp.manifest", "w") as f:
    f.write(manifest)

import win32api, win32con
handle = win32api.BeginUpdateResource("dist\\FastSync.exe", False)
with open("temp.manifest", "rb") as f:
    data = f.read()
win32api.UpdateResource(handle, 24, 1, data)
win32api.EndUpdateResource(handle, False)
os.remove("temp.manifest")
print("Manifest patched successfully!")