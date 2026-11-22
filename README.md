# Fray – Vagrant in cloud-init

Fray je aplikacija za zasebno beleženje časa in deljenje mesečnih seštevkov projektov. Ekipa 24 je pripravila dve postavitvi iste aplikacije na Ubuntu 24.04. Obe uporabljata spletni odjemalec Flutter, Django z Gunicornom, Nginx, PostgreSQL in Redis. [Izvorna koda aplikacije](https://github.com/ELITE-Salty/fray)

| Različica | Kako deluje | Navodila |
|---|---|---|
| Vagrant | `vagrant up` zažene VM v VirtualBoxu in izvede namestitvene skripte. Lokalni overitelj podpiše certifikat za `fray.test`. | [Zagon, preverjanje in obnova podatkov](vagrant/README.md) |
| Cloud-init | QEMU/KVM zažene VM na prenosniku. Ob prvem zagonu Ubuntu prebere nosilec `CIDATA` in postavi Fray iz izdaje na nosilcu `FRAYAPP`. Za javni HTTPS uporablja Let’s Encrypt. | [Zagon, omrežje in javni HTTPS](cloud-init/README.md) |

[Prvi zagon cloud-init](cloud-init/README.md#first-boot) · [Posnetki postavitve in uporabe](cloud-init/README.md#deployment-screenshots) · [Težave, na katere smo naleteli](cloud-init/README.md#problems-we-encountered)
