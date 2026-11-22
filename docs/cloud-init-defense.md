# Defending the Fray cloud-init deployment

Start with three questions. What happens when a new VM boots? What happens when somebody opens Fray? How would you prove that it worked? Practice tracing each answer through the actual files. Then cover the answers below and try the questions aloud.

## 1. What happens when a new VM boots?

**Who creates the VM, and who configures it?** The launcher starts QEMU on the CachyOS laptop. QEMU uses Linux KVM for hardware virtualization. Docker supplies the QEMU executable. Inside that virtual machine, Ubuntu boots its own kernel and starts systemd, its service manager. Ubuntu already includes cloud-init, the program that reads our first-boot settings. Fray's application services run directly inside Ubuntu. [Laptop launcher](../cloud-init/laptop/start.sh)

**Which file do I give to cloud-init?** On the laptop, `prepare.py` takes the template and fills in values such as the hostname and the release checksum. It saves the result as `user-data.yaml` in the kit and puts the same text on a virtual CD named `CIDATA` as `user-data`. Ubuntu's NoCloud data source discovers that CD. It also reads the instance ID and network configuration there. A second CD, `FRAYAPP`, carries the release and private configuration. Building the Flutter website on the laptop lets us reuse the compiled files on later deployments. The VM still needs the network for software packages. [Renderer](../cloud-init/prepare.py) · [Release builder](../scripts/build-release.sh)

**Where does PostgreSQL actually get installed?** Follow these three lines of responsibility:

1. In the YAML, `write_files` creates a root-owned executable named `/usr/local/sbin/fray-provision`. The indented text after `content: |` is the content written to that file.
2. `runcmd` names that executable. Cloud-init prepares the command during its configuration stage. On our Ubuntu image, the final stage installs the packages listed in the YAML before `scripts-user` executes the command. The module order explains why the tools are available.
3. `fray-provision` mounts `FRAYAPP` read-only, verifies the release checksum, extracts the files, and runs `guest/install.sh`. Find `apt-get install` there. It installs PostgreSQL along with Nginx, Redis and the other services. The installer uses a Python virtual environment and pip for the application's pinned Python libraries. [Cloud-config](../cloud-init/user-data.template.yaml) · [Installer](../cloud-init/guest/install.sh) · [Cloud-init module reference](https://docs.cloud-init.io/en/latest/reference/modules.html#runcmd)

**Why check a SHA-256 checksum?** The template renderer records the expected fingerprint of the release. The guest computes the fingerprint again before extracting it. A damaged archive or one paired with the wrong seed fails this comparison. Trust still starts with the person who produced the kit. Someone who could replace both the archive and its expected fingerprint could make them agree.

**What happens after a reboot?** Cloud-init's per-instance setup normally runs on the first boot of that instance. Enabled systemd services start again on ordinary reboots. The database, authentication keys and Grafana state live on the VM's writable disk. Creating a fresh disk creates a fresh installation. Recovering existing accounts requires their database and the original application secrets, including the key used to decrypt MFA enrollment data. A brief reboot tests persistence. A restore onto a separate disk tests backups. [Guest operations](../cloud-init/README.md)

## 2. What happens when somebody opens Fray?

Use a phone on mobile data to trace the path. DNS resolves `fray-cloud.klanija.com` to the home router's public IPv4. The router forwards TCP 443 to `192.168.64.131:18443` on the laptop. QEMU forwards it to port 443 in Ubuntu. Nginx presents the HTTPS certificate, reads the request path, and chooses where to send it. [Laptop network settings](../cloud-init/README.md) · [Nginx configuration](../cloud-init/guest/nginx.conf)

| Request | What answers it? |
|---|---|
| `/` | Nginx serves the compiled Flutter website. |
| `/api/health` | Nginx forwards to Gunicorn at `127.0.0.1:8000`. Gunicorn runs the Django code. Django executes `SELECT 1` in PostgreSQL and writes and reads a small Redis value. Both checks must pass for HTTP 200. |
| `/grafana/` | Nginx forwards to Grafana at `127.0.0.1:3000`. Grafana authenticates its own users. An anonymous request to its protected user API gets 401. |
| `/.well-known/acme-challenge/…` over HTTP | The router forwards public TCP 80 to laptop port 18080, then QEMU forwards it to guest port 80. Nginx serves the temporary file that proves control of the hostname to Let's Encrypt. Other HTTP requests redirect to HTTPS. |

**Why are both PostgreSQL and Redis needed?** PostgreSQL holds durable records such as users, time entries and database-backed sessions. Redis accelerates session reads and holds short-lived counters such as login throttles. Django connects to PostgreSQL locally as the Linux service account `fray`. PostgreSQL peer authentication checks the operating-system identity. Redis uses a Unix socket whose file permissions allow the service to connect. Neither service needs a router port forward. [Django settings](https://github.com/ELITE-Salty/fray/blob/595cd68a42fba0ad2c6c3f7b802aff85010c8622/backend/fray/settings.py) · [Guest installer](../cloud-init/guest/install.sh)

**What is the difference between authentication and authorization in our app?** Signing in with a password and an authenticator code proves identity. Authorization decides which records that identity can access. For example, a project member may see the shared monthly total while another member's individual entries and notes stay private. A good demo uses two accounts and one shared project. [Fray account and sharing behavior](https://github.com/ELITE-Salty/fray/blob/595cd68a42fba0ad2c6c3f7b802aff85010c8622/docs/app-features.md)

**What did our signup email issue teach us?** The sign-up flow sends an email code to verify the address, then enrolls the authenticator. The SMTP username and password let Fray connect to Mailjet. The From address identifies the sender and must be permitted by the provider. A successful SMTP login, a message accepted for processing, and a message arriving in an inbox are three separate checks. We corrected the From address in the private settings, applied it to the VM and restarted Fray so its process loaded the change. [Signup code](https://github.com/ELITE-Salty/fray/blob/595cd68a42fba0ad2c6c3f7b802aff85010c8622/backend/tracker/auth_views.py) · [Mail diagnostic](https://github.com/ELITE-Salty/fray/blob/595cd68a42fba0ad2c6c3f7b802aff85010c8622/backend/tracker/management/commands/check_email.py)

**Where are the secrets?** The private workstation `.env` supplies optional Grafana and SMTP values when creating a kit. Inside Ubuntu, systemd reads `/etc/fray/app.env`, `site.env` and the optional `mail.env` for the application. Grafana reads its own environment file. Its initial admin password seeds its database on a fresh installation. Rotating an existing login also requires updating the account in Grafana. The repository can contain the example settings. Keep the populated file, private ISO, VM disk, passwords and MFA recovery codes out of the submission and recording. [Example settings](../cloud-init/.env.example) · [Application service](../cloud-init/guest/fray.service)

**Why do we need the domain, port 80 and a certificate?** Cloudflare provides DNS for this laptop setup. Certbot asks Let's Encrypt for a certificate matching the public name. For HTTP-01, Let's Encrypt retrieves a challenge file through port 80. After a successful staging check and production issuance, Nginx uses the certificate on port 443. A systemd timer schedules renewal checks, and a deploy hook reloads Nginx when the certificate changes. A phone reaching the test file proves the public route works. A successful HTTPS request with normal certificate verification also tests the hostname and certificate trust. [ACME service and timer](../cloud-init/laptop/acme-files.yaml) · [Certificate helper](../cloud-init/guest/fray-acme)

## 3. How do I prove it works?

**What does each monitoring component do?** A log records an event such as one HTTP request. A metric is a number sampled over time, such as the request rate. Nginx and the app write logs to the system journal. Alloy reads those entries, labels them, and sends them to Loki for storage and search. Prometheus scrapes application metrics and host metrics from Node Exporter every 15 seconds. Grafana queries Loki and Prometheus to display the results. A stopped Grafana can leave the time tracker working while the dashboard is unavailable. [Alloy inputs](../cloud-init/guest/config.alloy) · [Prometheus targets](../cloud-init/guest/prometheus.yml) · [Grafana data sources](../cloud-init/guest/datasources.yaml)

**Rehearse this short demo.** Know where each command runs and what its result proves.

1. Inside the **Ubuntu VM**, run `cloud-init status --long`. Explain what `done` means, then run `systemctl is-active fray nginx redis-server grafana-server prometheus alloy loki` to check the current services. Setup completed in the past. Service status tells you whether each is running now.
2. From a **browser or terminal outside the VM**, open `https://fray-cloud.klanija.com/api/health`. Expect `{"status":"ok"}`. Then run `curl -s -o /dev/null -w '%{http_code}\n' https://fray-cloud.klanija.com/api/entries` without login cookies. Expect 401. One result exercises the dependencies, the other exercises access control.
3. In **Grafana → Explore → Fray logs**, run `{service="nginx"} |= "/api/health"` over the last five minutes. Point out the request you just generated. Explain the journey from Nginx through the journal and Alloy to Loki.
4. In the **VM**, run `sudo certbot certificates` and `systemctl list-timers certbot.timer`. Point to the hostname, expiry and next scheduled renewal check. In the browser, show that the public HTTPS connection is trusted.

**How fast is a deployment?** A fresh local benchmark took 2 min 41 sec from launch to health checks on 2 vCPUs and 4 GiB RAM with a cached Ubuntu image and a prepared Fray release. It verified the API, Grafana login page and an access log in Loki. Public certificate enrollment was measured separately on the live VM at 19 seconds. The benchmark used a private certificate and left the live hostname alone.

**What would you investigate first if it broke?**

| Symptom | First check and reason |
|---|---|
| Phone times out, but the laptop listener works | Check the DNS answer, laptop address, router forwards, firewall and whether the laptop is awake. The local test skips part of the public path. |
| Nginx returns 502 for the API | Check `systemctl status fray` and `sudo journalctl -u fray -n 30`. Nginx answered, but it could not get a usable response from Gunicorn. |
| `/api/health` returns Fray's 503 response | Check the PostgreSQL and Redis services. The Django endpoint returns 503 when its database or cache check fails. |
| The app answers, but its recent requests are missing in Grafana | Check the time range and Loki data source, then look in the Nginx journal and check Alloy and Loki. This tests each step in log collection. |
| SMTP connects, but the verification code never arrives | Check the signup response, mail failure metrics and provider delivery history for the recipient. Also check sender verification and the recipient's spam folder. |

## 4. How does my colleague's Vagrant version differ?

Both versions aim to boot Ubuntu and provision Fray. In the team repository reviewed on 22 November 2026, Vagrant tells VirtualBox to create the VM, uploads scripts and release artifacts, then invokes numbered shell provisioning steps. The laptop cloud-init version starts QEMU with two virtual CDs and lets Ubuntu discover its setup at first boot. Verify these details with your teammate against the final commit you submit. [Team Vagrantfile](https://github.com/devops-fri-26/sk-24-virtualization/blob/main/vagrant/Vagrantfile)

| Topic | Team Vagrant implementation reviewed | Laptop cloud-init implementation |
|---|---|---|
| Network and TLS | Private address `192.168.56.10`. The committed TLS script issues a certificate from a local CA and configures a timer. Clients need to trust that CA. | Public hostname, router forwarding, Certbot HTTP-01 and a browser-trusted Let's Encrypt certificate. |
| Monitoring | Grafana provisions a PostgreSQL monitoring data source and dashboard. | Grafana provisions Prometheus for metrics and Loki for searchable logs. |
| Recovery | The backup script configures a daily database dump and includes a restore drill. | The laptop uses a persistent disk. The cloud-init recovery guide describes restoring data and secrets. A scheduled database backup and restore drill would require separate implementation and evidence here. |

[Vagrant TLS](https://github.com/devops-fri-26/sk-24-virtualization/blob/main/vagrant/provision/40-tls.sh) · [Vagrant monitoring](https://github.com/devops-fri-26/sk-24-virtualization/blob/main/vagrant/provision/60-monitoring.sh) · [Vagrant backups](https://github.com/devops-fri-26/sk-24-virtualization/blob/main/vagrant/provision/70-backup.sh)

## Practice without the answers

1. I see four packages in your YAML. Show me where PostgreSQL comes from. What makes the installation happen?
2. If I unplug the virtual CD holding the application before the first boot, where does setup fail? What evidence would you look for?
3. A user gets HTTP 200 on the home page but 503 on the health endpoint. How can both responses be correct?
4. Why can someone reach Grafana on the public website when port 3000 has no router forwarding rule?
5. You have a database backup and a new VM. What else would you need before existing users could sign in with their enrolled authenticators?
6. Which parts of the 2 min 41 sec measurement would change on a laptop starting without any downloaded images or built application release?
