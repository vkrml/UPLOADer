#!/bin/bash

# ==========================================
# Secure Asset Transfer Protocol Script
# ==========================================

echo "Initializing Secure Runtime..."

# Embed the Python logic securely
cat << 'EOF' > engine.py
import os
import sys
import re
import time
import shutil
import uuid
import zipfile
import subprocess
import urllib.parse
import concurrent.futures
from pathlib import Path

# --- Configuration & Secrets ---
HF_TOKEN = os.environ.get('AUTH_TOKEN')
REPO_ID = os.environ.get('TARGET_ID')
PATH_IN_REPO = os.environ.get('TARGET_PATH', '')
BRANCH = os.environ.get('TARGET_REF', 'main')
WORKERS = int(os.environ.get('WORKER_COUNT', 4))
INPUT_LINKS = os.environ.get('INPUT_LINKS', '')

if not HF_TOKEN or not REPO_ID:
    print("❌ Error: Security credentials missing.")
    sys.exit(1)

# --- stealth_lib: Wraps HF Logic ---
try:
    from huggingface_hub import HfApi
    from tqdm import tqdm
    import aria2p
except ImportError:
    print("❌ Environment corrupted. Missing libs.")
    sys.exit(1)

class StealthUploader:
    def __init__(self):
        self.api = HfApi(token=HF_TOKEN)
        self.download_dir = "temp_dl"
        self.extract_dir = "temp_ex"
        self._setup_dirs()
        self.aria2 = self._init_aria2()
        
        # Verify Auth (Silent)
        try:
            self.api.whoami()
            print("✅ Secure Connection Established")
        except Exception:
            print("❌ Authentication Failed")
            sys.exit(1)

    def _setup_dirs(self):
        for d in [self.download_dir, self.extract_dir]:
            if os.path.exists(d): shutil.rmtree(d)
            os.makedirs(d, exist_ok=True)

    def _init_aria2(self):
        try:
            subprocess.Popen(
                ["aria2c", "--enable-rpc", "--daemon", "--check-certificate=false"],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
            )
            time.sleep(2)
            aria = aria2p.API(aria2p.Client(host="http://localhost", port=6800, secret=""))
            print("🚀 High-Speed Engine: Active")
            return aria
        except:
            print("⚠️ Standard Engine: Active")
            return None

    def sanitize_name(self, name):
        name = re.sub(r'[<>:"/\\|?*\x00-\x1f]', '_', name)
        return name.strip('. ') or f"file_{uuid.uuid4().hex[:6]}"

    def get_filename(self, url):
        try:
            import requests
            r = requests.head(url, allow_redirects=True, timeout=10)
            cd = r.headers.get('content-disposition')
            if cd:
                fname = re.findall("filename=(.+)", cd)
                if fname: return self.sanitize_name(fname[0].strip('"\''))
            return self.sanitize_name(os.path.basename(urllib.parse.urlparse(url).path))
        except:
            return f"data_{uuid.uuid4().hex[:6]}.bin"

    def download(self, url, filename):
        out_path = os.path.join(self.download_dir, filename)
        print(f"⬇️  Acquiring: {filename}")
        
        if self.aria2:
            try:
                d = self.aria2.add_uris([url], options={'dir': self.download_dir, 'out': filename})
                while not d.is_complete:
                    d.update()
                    time.sleep(1)
                    if d.has_failed: raise Exception("Aria2 Error")
                return out_path
            except:
                pass # Fallback
        
        # Requests fallback
        import requests
        with requests.get(url, stream=True) as r:
            r.raise_for_status()
            with open(out_path, 'wb') as f:
                for chunk in r.iter_content(8192): f.write(chunk)
        return out_path

    def extract(self, archive_path):
        print(f"📦 Extracting package...")
        extracted_files = []
        try:
            import rarfile
            # Check type
            if archive_path.lower().endswith('.zip'):
                opener, mode = zipfile.ZipFile, 'r'
            elif archive_path.lower().endswith('.rar'):
                opener, mode = rarfile.RarFile, 'r'
            else:
                return []

            with opener(archive_path, mode) as z:
                for member in z.namelist():
                    # Security check for paths
                    if '..' in member or member.startswith('/'): continue
                    z.extract(member, self.extract_dir)
                    full_path = os.path.join(self.extract_dir, member)
                    if os.path.isfile(full_path):
                        extracted_files.append(full_path)
            return extracted_files
        except Exception as e:
            print(f"⚠️ Extraction Error: {e}")
            return []

    def upload(self, local_path):
        filename = os.path.basename(local_path)
        remote = f"{PATH_IN_REPO}/{filename}" if PATH_IN_REPO else filename
        
        try:
            self.api.upload_file(
                path_or_fileobj=local_path,
                path_in_repo=remote,
                repo_id=REPO_ID,
                revision=BRANCH,
                commit_message=f"Sync: {filename}"
            )
            print(f"✅ Synced: {filename}")
            return True
        except Exception as e:
            print(f"❌ Sync Failed {filename}: {e}")
            return False

def process_line(line, engine):
    line = line.strip()
    if not line: return
    
    mode = "direct"
    url = line
    rename = None
    
    # Parse Flags
    if " -unzip" in line:
        mode = "unzip"
        url = line.replace(" -unzip", "").strip()
    elif " -n " in line:
        parts = line.split(" -n ")
        url = parts[0].strip()
        rename = parts[1].strip()
    
    # 1. Download
    fname = rename if rename else engine.get_filename(url)
    fpath = engine.download(url, fname)
    
    if not os.path.exists(fpath): return

    files_to_upload = []
    
    # 2. Extract or Keep
    if mode == "unzip":
        extracted = engine.extract(fpath)
        files_to_upload.extend(extracted)
        os.remove(fpath) # Cleanup archive
    else:
        files_to_upload.append(fpath)

    # 3. Upload (Concurrent)
    with concurrent.futures.ThreadPoolExecutor(max_workers=WORKERS) as executor:
        futures = {executor.submit(engine.upload, f): f for f in files_to_upload}
        for fut in concurrent.futures.as_completed(futures):
            fut.result()

def main():
    engine = StealthUploader()
    lines = INPUT_LINKS.split('\n') # Github sends newlines differently sometimes
    if not lines: lines = INPUT_LINKS.split() 
    
    # Filter empty
    tasks = [l.strip() for l in lines if l.strip()]
    
    print(f"📋 Processing {len(tasks)} tasks with {WORKERS} workers...")
    
    for task in tasks:
        process_line(task, engine)
        
    print("\n🎉 Protocol Complete.")

if __name__ == "__main__":
    main()
EOF

# Execute the engine
python3 engine.py
