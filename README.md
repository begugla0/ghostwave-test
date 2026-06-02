# GhostWave Client

Кроссплатформенный GUI клиент для подключения к GhostWave VPN.
Работает на **Windows / Linux / macOS** без установки — только Python 3.10+.

## Быстрая установка

### Windows
```cmd
# 1. Установить Python 3.12 с https://python.org (добавить в PATH)
# 2. Установить зависимости:
pip install cryptography httpx

# 3. Запустить от Администратора:
python ghostwave-client.py
```

### Ubuntu / Debian
```bash
sudo apt install python3 python3-pip python3-tk

pip3 install cryptography httpx

# Запуск с правами (нужны для TUN):
sudo python3 ghostwave-client.py
```

### macOS
```bash
brew install python-tk

pip3 install cryptography httpx

sudo python3 ghostwave-client.py
```

## Использование

1. **Вкладка «Подписка»** → вставьте Subscription URL от администратора → «Сохранить и обновить»
2. **Вкладка «Подключение»** → выберите сервер из списка → «ПОДКЛЮЧИТЬ»
3. Готово — весь трафик идёт через GhostWave

## Требования

| Компонент | Версия |
|-----------|--------|
| Python    | 3.10+  |
| cryptography | 43.x |
| httpx     | 0.27+  |
| tkinter   | (входит в стандартную поставку Python) |

## Структура конфига

Конфиг клиента сохраняется в `~/.ghostwave/config.json`.
Subscription URL и список нод обновляются автоматически при нажатии «⟳».

## Subscription URL форматы

Клиент поддерживает URL вида:
```
https://panel.example.com/sub/ВАШ_ТОКЕН
```

При загрузке автоматически запрашивает `?fmt=json` для получения
конфигурации в нативном формате GhostNet.
