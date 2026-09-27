import subprocess

if __name__ == "__main__":
    for project in ['arizona']:
        print(f"\n{'='*50}")
        print(f"[INFO] ⚡ STARTING BUILD FOR: {project}")
        print(f"{'='*50}\n")
        
        subprocess.run(["python", "build_launcher.py", project], check=True)