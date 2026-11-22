#!/usr/bin/env python3
"""Prepare the Fray application ISO and NoCloud seed for a QEMU/KVM laptop VM."""
import argparse
import fcntl
import hashlib
import ipaddress
import json
import os
from pathlib import Path
import re
import secrets
import shutil
import subprocess
import tempfile


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def openssl(*args):
    subprocess.run(["openssl", *args], check=True, stdout=subprocess.DEVNULL)


def package_environment(path, media):
    """Read literal values without executing them. Only the private release ISO carries secrets."""
    if path is None:
        return ""
    keys = {"GF_SECURITY_ADMIN_PASSWORD", "FRAY_SIGNUP_ENABLED", "FRAY_EMAIL_HOST",
            "FRAY_EMAIL_PORT", "FRAY_EMAIL_USE_TLS", "FRAY_EMAIL_USE_SSL", "FRAY_EMAIL_USER",
            "FRAY_EMAIL_PASSWORD", "FRAY_EMAIL_FROM"}
    values = {}
    for number, line in enumerate(path.read_text().splitlines(), 1):
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        key, sep, value = line.partition("=")
        if not sep or key not in keys or key in values or "\0" in value:
            raise ValueError(f"Invalid or repeated setting on line {number} of the deployment env file.")
        values[key] = value
    signup = values.get("FRAY_SIGNUP_ENABLED", "0")
    if signup not in ("0", "1"):
        raise ValueError("Set FRAY_SIGNUP_ENABLED to 0 or 1.")
    files = {}
    if signup == "1":
        mail = {k: values.get(k, "") for k in sorted(keys) if k.startswith("FRAY_")}
        if not all(mail.values()):
            raise ValueError("Fill all SMTP settings before enabling signup.")
        if not mail["FRAY_EMAIL_PORT"].isascii() or not mail["FRAY_EMAIL_PORT"].isdigit() or not 0 < int(mail["FRAY_EMAIL_PORT"]) <= 65535:
            raise ValueError("Enter a valid SMTP port.")
        if (mail["FRAY_EMAIL_USE_TLS"], mail["FRAY_EMAIL_USE_SSL"]) not in (("1", "0"), ("0", "1")):
            raise ValueError("Choose STARTTLS or implicit TLS for SMTP authentication.")
        files["mail.env"] = mail
    if values.get("GF_SECURITY_ADMIN_PASSWORD"):
        files["grafana.env"] = {"GF_SECURITY_ADMIN_PASSWORD": values["GF_SECURITY_ADMIN_PASSWORD"]}
    commands = []
    for name, settings in files.items():
        # systemd EnvironmentFile double-quoted values preserve spaces and punctuation.
        lines = []
        for key, value in settings.items():
            quoted = value.replace("\\", "\\\\").replace('"', '\\"')
            lines.append(f'{key}="{quoted}"\n')
        (media / name).write_text("".join(lines))
        commands.append(f"      if [[ ! -e /etc/fray/{name} ]]; then\n"
                        f"          install -m 0600 {name} /etc/fray/{name}\n"
                        "      fi")
    return "\n".join(commands)


def prepare(args):
    domain = args.domain.lower()
    label = r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?"
    if len(domain) > 253 or not re.fullmatch(rf"{label}(?:\.{label})+", domain):
        raise ValueError("Enter the public DNS hostname, without https:// or a port.")
    if not re.fullmatch(label, args.vm_name):
        raise ValueError("Enter a single DNS label for the VM name.")
    acme_files = acme_start = ""
    if args.acme_email_file:
        email = args.acme_email_file.read_text().strip()
        if not re.fullmatch(rf"[a-zA-Z0-9_.+%-]+@{label}(?:\.{label})+", email, re.IGNORECASE):
            raise ValueError("Enter one contact email in the ACME email file.")
        template = Path(__file__).parent / "laptop" / "acme-files.yaml"
        acme_files = template.read_text().rstrip().replace("@EMAIL@", email)
        acme_start = ("      systemctl daemon-reload\n"
                      "      systemctl enable --now fray-acme-enroll.timer\n"
                      "      systemctl start fray-acme-enroll.service")
    admin = ipaddress.IPv4Network(args.admin_cidr)
    password = None
    if args.ssh_key:
        key = args.ssh_key.read_text().strip()
        if "\n" in key or not key.startswith(("ssh-", "ecdsa-", "sk-")):
            raise ValueError("Supply one OpenSSH public key.")
        subprocess.run(["ssh-keygen", "-lf", args.ssh_key], check=True, stdout=subprocess.DEVNULL)
        login = "ssh_authorized_keys:\n  - " + json.dumps(key)
    else:
        password = secrets.token_urlsafe(20)
        hashed = subprocess.check_output(["openssl", "passwd", "-6", "-stdin"],
                                         input=password + "\n", text=True).strip()
        login = ("chpasswd:\n  expire: true\n  users:\n    - name: ubuntu\n"
                 f"      type: hash\n      password: '{hashed}'")
    args.output.mkdir(parents=True, exist_ok=True)
    ca_dir = args.ca_dir.resolve()
    ca_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
    ca_key, ca_cert = ca_dir / "ca.key", ca_dir / "ca.crt"
    # Parallel builds for a site must share the same issuer.
    with (ca_dir / ".lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        if not ca_key.exists() and not ca_cert.exists():
            with tempfile.TemporaryDirectory(dir=ca_dir) as tmp:
                pair = Path(tmp)
                openssl("req", "-x509", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:P-256",
                        "-nodes", "-days", "3650", "-subj", "/CN=Fray origin CA",
                        "-addext", "basicConstraints=critical,CA:TRUE,pathlen:0",
                        "-addext", "keyUsage=critical,keyCertSign,cRLSign",
                        "-keyout", pair / "key", "-out", pair / "cert")
                (pair / "key").rename(ca_key)
                (pair / "cert").rename(ca_cert)
        if not ca_key.is_file() or not ca_cert.is_file():
            raise ValueError("Incomplete issuer. Restore the existing CA certificate and key.")

    with tempfile.TemporaryDirectory(dir=args.output) as tmp:
        build = Path(tmp)
        media = build / "media"
        media.mkdir()
        env_setup = package_environment(args.env_file, media)
        shutil.copyfile(args.release, media / "release.tgz")
        shutil.copyfile(ca_cert, media / "origin-ca.crt")
        openssl("req", "-new", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:P-256", "-nodes",
                "-subj", f"/CN={domain}", "-keyout", media / "origin.key", "-out", build / "leaf.csr")
        ext = build / "leaf.ext"
        names = f"DNS:{domain},IP:10.0.2.15,DNS:localhost,IP:127.0.0.1"
        ext.write_text(f"subjectAltName={names}\nbasicConstraints=critical,CA:FALSE\n"
                       "keyUsage=critical,digitalSignature\nextendedKeyUsage=serverAuth\n")
        openssl("x509", "-req", "-in", build / "leaf.csr", "-CA", ca_cert, "-CAkey", ca_key,
                "-set_serial", str(secrets.randbits(128) or 1), "-days", "365",
                "-extfile", ext, "-out", media / "origin.crt")
        openssl("verify", "-CAfile", ca_cert, "-verify_hostname", domain, media / "origin.crt")
        kit = build / "kit"
        kit.mkdir()
        config = Path(__file__).with_name("user-data.template.yaml").read_text()
        substitutions = {"DOMAIN": domain, "ADMIN_NET": str(admin),
                         "LOGIN": login, "VM_NAME": args.vm_name, "SSH_MODE": "key" if args.ssh_key else "console", "RELEASE_SHA": digest(media / "release.tgz"),
                         "CERT_SHA": digest(media / "origin.crt"), "KEY_SHA": digest(media / "origin.key"),
                         "CA_SHA": digest(ca_cert), "ACME_FILES": acme_files,
                         "ACME_START": acme_start, "ENV_SETUP": env_setup,
                         "GRAFANA_ACCESS": "public" if args.public_grafana else "private"}
        # Single pass preserves punctuation in the user's SSH key comment.
        config = re.sub(r"@([A-Z_]+)@", lambda m: substitutions[m[1]], config)
        (kit / "user-data.yaml").write_text(config)
        shutil.copyfile(ca_cert, kit / "origin-ca.crt")
        (media / "user-data.yaml").write_text(config)
        if password:
            (kit / "console-password.txt").write_text(password + "\n")
        kit_id = f"{domain}-{digest(kit / 'user-data.yaml')[:16]}"
        subprocess.run(["bsdtar", "-cf", kit / f"{kit_id}.iso", "--format", "iso9660", "--options",
                        "iso9660:volume-id=FRAYAPP", "-C", media, "."], check=True)
        seed = build / "seed"
        seed.mkdir()
        (seed / "user-data").write_text(config)
        (seed / "meta-data").write_text(f"instance-id: {kit_id}\nlocal-hostname: {args.vm_name}\n")
        # The single virtio NIC obtains the QEMU user-network address and DNS by DHCP.
        (seed / "network-config").write_text("version: 2\nethernets:\n  lan:\n    match: {driver: virtio_net}\n    dhcp4: true\n")
        subprocess.run(["bsdtar", "-cf", kit / "cidata.iso", "--format", "iso9660", "--options",
                        "iso9660:volume-id=CIDATA", "-C", seed, "."], check=True)
        dest = args.output / kit_id
        kit.rename(dest)
    print(dest.resolve())


if __name__ == "__main__":
    os.umask(0o077)
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--release", type=Path, required=True, help="archive from build-release.sh")
    p.add_argument("--domain", required=True)
    p.add_argument("--public-grafana", action="store_true", help="publish the authenticated Grafana UI at /grafana/ on the application hostname")
    p.add_argument("--env-file", type=Path, help="private Grafana and SMTP inputs, formatted like .env.example")
    p.add_argument("--laptop", action="store_true", help=argparse.SUPPRESS)
    p.add_argument("--acme-email-file", type=Path, help="enable first-boot Let's Encrypt enrollment with this contact email and accept its subscriber agreement")
    p.add_argument("--vm-name", default="fray")
    p.add_argument("--guest-cidr", choices=["10.0.2.15/24"], help=argparse.SUPPRESS)
    p.add_argument("--gateway", choices=["10.0.2.2"], help=argparse.SUPPRESS)
    p.add_argument("--ssh-key", type=Path, help="optional OpenSSH public key; default is a serial-console password")
    p.add_argument("--admin-cidr", default="10.0.2.0/24", help="guest firewall source range for management access")
    p.add_argument("--ca-dir", type=Path, required=True, help="persistent private origin CA directory")
    p.add_argument("--output", type=Path, default=Path("dist/fray-laptop/kits"))
    prepare(p.parse_args())
