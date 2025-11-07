# pi5_setup_script

I use this script to restore my raspberry pi configuration.

## How to use the script
1. Connect to your pi via SSH.
2. Download the script
```bash
curl -O https://raw.githubusercontent.com/WUOTE/pi5_setup_script/refs/heads/main/pi5_setup.sh
```
3. Make the script executable
```bash
chmod +x pi5_setup.sh
```
4. Run the script and follow the prompts
```bash
./pi5_setup.sh
```

Skip the steps you don't need: unless you are using the same [Argon case](https://argon40.com/products/argon-one-v3-m-2-nvme-case) as I do, skip stages `1`, `2` and `3`, and you probably dont need my custom n8n workflows made for dunkbin cosmetics, hence skip stages `9` and `10`.
