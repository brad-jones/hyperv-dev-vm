echo "Install Misc Tools";
echo "--------------------------------------------------------------------------------";
sudo dnf install -y jq tar tree;

echo "Install VsCode Executor";
echo "--------------------------------------------------------------------------------";
sudo mkdir -p /usr/local/bin;
sudo mv /tmp/code /usr/local/bin/code;
sudo chmod +x /usr/local/bin/code;

echo "Cleanup";
echo "--------------------------------------------------------------------------------";
sudo rm -rf /tmp/*;
ls -hal /tmp;
