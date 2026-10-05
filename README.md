# BOTICS_FRIENDS installer

Основная установка BOTICS:

```bash
curl -sSL https://raw.githubusercontent.com/xXAllenWalkerXx/BOTICS_FRIENDS_INSTALL/main/install.sh | sudo bash
```

Установка нового 3x-ui Node для подключения к существующей master-панели:

```bash
curl -fsSL https://raw.githubusercontent.com/xXAllenWalkerXx/BOTICS_FRIENDS_INSTALL/main/xui-node.sh -o /tmp/botics-xui-node.sh
sudo bash /tmp/botics-xui-node.sh
```

Версии по умолчанию: 3x-ui `v3.8.5`, Xray-core `v26.7.28`. Скрипт содержит
только публичную логику установки и не содержит токены или код приватного
репозитория BOTICS_FRIENDS.
