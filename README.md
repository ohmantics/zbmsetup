# zbmsetup
These scripts automate the way I like my [Proxmox](https://www.proxmox.com/en/) ZFS-on-root installs to work using [ZFSBootMenu](https://zfsbootmenu.org/) instead of GRUB. This enables Proxmox ZFS boot environments for safer upgrades. If that resonates with you, consider chiming in on [this bug](https://bugzilla.proxmox.com/show_bug.cgi?id=6709).

⚠️ These scripts worked for me. The LLM that did the grunt work of converting my hand-taken notes into these scripts was pretty insistent on adding support for encryption, and that's the one feature here I haven't tested at all, so YMMV.
## How to use

On your host machine, edit config.sh accordingly. Then cd into this directory and then run "python3 -m http.server 8000". This serves these files for the bare metal target to access.
### via Proxmox 9.1.1 ISO

From the installer UI, I select "Advanced," then pick the "Terminal UI (Debug)" option. You'll need to hit Ctrl-D a few times until you see the network interfaces obtain addresses and then from the installer's TUI, select "abort." You're then dropped into the Proxmox live environment shell. Do this:

```
wget http://<your IP>:8000/zbmsetup/config.sh
wget http://<your IP>:8000/zbmsetup/install.sh
chmod +x config.sh install.sh
./install.sh
```

### via Debian 13.3.0 Trixie ISO

From the installer UI, select the "live environment" option. Then run these commands:

```
sudo su
cd
curl http://<your IP>:8000/zbmsetup/config.sh
curl http://<your IP>:8000/zbmsetup/install.sh
chmod +x config.sh install.sh
./install.sh
```
