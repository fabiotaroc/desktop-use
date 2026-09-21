#!/usr/bin/env python3
"""Keep one local signing identity across builds without changing OS trust settings."""
import os
from pathlib import Path
import secrets
import shlex
import subprocess
import sys
import tempfile

os.umask(0o077)
folder = Path.home() / "Library/Application Support/Desktop Use/Signing"
folder.mkdir(parents=True, exist_ok=True, mode=0o700)
keychain = folder / "signing.keychain-db"
password_file = folder / "keychain-password"
identity_file = folder / "identity"
password = password_file.read_text() if password_file.exists() else secrets.token_urlsafe(32)


def run(*args):
    result = subprocess.run(args, capture_output=True, text=True)
    if result.returncode:
        raise RuntimeError(f"{Path(args[0]).name}: {result.stderr.replace(password, '[redacted]').strip()}")
    return result.stdout.strip()


try:
    if not identity_file.exists():
        if keychain.exists():
            raise RuntimeError("Local signing setup is incomplete. Preserve the existing keychain and repair setup before signing.")
        password_file.write_text(password)
        old_search_list = shlex.split(run("security", "list-keychains", "-d", "user"))
        try:
            run("security", "create-keychain", "-p", password, str(keychain))
            with tempfile.TemporaryDirectory(prefix="desktop-use-signing-") as temporary:
                temp = Path(temporary)
                private_key, certificate, archive = (temp / name for name in ("key.pem", "cert.pem", "identity.p12"))
                run("/usr/bin/openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-sha256",
                    "-keyout", str(private_key), "-out", str(certificate), "-days", "3650",
                    "-subj", "/CN=Desktop Use Local Development/",
                    "-addext", "basicConstraints=critical,CA:FALSE",
                    "-addext", "keyUsage=critical,digitalSignature",
                    "-addext", "extendedKeyUsage=critical,codeSigning")
                run("/usr/bin/openssl", "pkcs12", "-export", "-inkey", str(private_key), "-in", str(certificate),
                    "-out", str(archive), "-passout", f"file:{password_file}")
                run("security", "import", str(archive), "-k", str(keychain), "-P", password,
                    "-x", "-T", "/usr/bin/codesign")
                run("security", "set-key-partition-list", "-S", "apple-tool:", "-s", "-k", password, str(keychain))
                fingerprint = run("/usr/bin/openssl", "x509", "-in", str(certificate), "-noout", "-fingerprint", "-sha1")
                identity_file.write_text(fingerprint.partition("=")[2].replace(":", "").strip())
        finally:
            run("security", "list-keychains", "-d", "user", "-s", *old_search_list)
    run("security", "unlock-keychain", "-p", password, str(keychain))
    old_search_list = shlex.split(run("security", "list-keychains", "-d", "user"))
    try:
        run("security", "list-keychains", "-d", "user", "-s", *old_search_list, str(keychain))
        run("codesign", "--force", "--sign", identity_file.read_text(), "--keychain", str(keychain),
            "--timestamp=none", "--identifier", "local.desktop-use", sys.argv[1])
    finally:
        run("security", "list-keychains", "-d", "user", "-s", *old_search_list)
    run("codesign", "--verify", "--strict", sys.argv[1])
    print("Signed with the persistent local identity.")
except Exception as error:
    print(str(error).replace(password, "[redacted]"), file=sys.stderr)
    sys.exit(1)
finally:
    if keychain.exists():
        subprocess.run(["security", "lock-keychain", str(keychain)], capture_output=True)
