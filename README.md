<div align="center">
  <a href="#english-version-us">🇺🇸 English</a> | <a href="#українська-версія-ua">🇺🇦 Українська</a>
</div>

---

# 🛡️ FABY Cloud - Zero-Knowledge Storage Engine

<div id="english-version-us"></div>

## 🇺🇸 English Version

**FABY Cloud** is the core of an absolute-privacy cloud storage solution, part of the [FABY](https://faby.world) / SHAS Development ecosystem.

This repository contains the **client-side (Flutter)** for virtual file system (VFS) and cryptography management, as well as the **public backend routes (FastAPI)**. We open-sourced this code to prove the transparency of our infrastructure and guarantee our adherence to **Zero-Knowledge (ZK)** principles.

### 📖 Why Partial Open Source? (Open Core)

The golden rule of Zero-Knowledge is: *"The server cannot be trusted."*
We have opened the core storage modules so any developer or cybersecurity expert can verify that:
1. **Our backend is completely "blind"**: The server operates only with anonymized UUIDs and encrypted bytes. It never sees your passwords, decryption keys, or even file names.
2. **Encryption happens strictly client-side**: Data is encrypted on your device before it ever touches the network.
3. **Direct-to-Cloud Uploads**: We do not proxy file traffic through our backend. Instead, we generate AWS S3 Presigned URLs for direct uploads to Cloudflare R2.

> **Note:** Routes for authentication, billing (Stripe), and internal business logic remain closed-source to protect our infrastructure from abuse. This repository focuses solely on the **Security & Storage Engine**.

### 🔐 Encryption Architecture (3 Layers)

FABY Cloud utilizes a robust multi-layered encryption architecture based on **AES-256-GCM**.

1. **File Level**
   Each file is streamed and encrypted with a unique, randomly generated key (`rawFileKey`). Files larger than 100 MB are automatically chunked into 50 MB parts and uploaded via Multipart Upload.
2. **Metadata Level**
   The file's key (`rawFileKey`) is encrypted using the user's **Master Key** (`userMasterKey`). Only the encrypted key (`encryptedFileKey`) is sent to the cloud, while the actual file name is hidden inside an encrypted JSON VFS Node.
3. **Recovery Level**
   To prevent Master Key loss when changing devices, a **12-word secret phrase** (BIP39) is generated. Using `PBKDF2` (100,000 iterations), a Key Encryption Key (KEK) is derived from this phrase to encrypt the Master Key for cloud backup. *We never have access to your secret phrase.*

### 🚀 Key Features

- **Local-First VFS:** The virtual file system is stored locally in an encrypted SQLite database and synced with the cloud using ETags.
- **Secure File Sharing:** When creating a public share link, the decryption key is embedded in the **URL fragment** (`#key=...`), which is never sent to the server, ensuring secure Client-Side Decryption.
- **Multipart Uploads:** Supports uploading large files up to 5 GB (platform limit) with chunk management.
- **Protected Trash:** Deleted files are retained for 7 days. The server supports secure restoration without the risk of overwriting active data.

### 🛠 Tech Stack

* **Client:** Flutter / Dart, `cryptography` (AES-GCM), `bip39`, `sqflite` (VFS Cache), `flutter_secure_storage`.
* **Backend:** Python, FastAPI, SQLAlchemy (PostgreSQL), Boto3, Cloudflare R2 (S3 API).

### 💡 How Secure Sharing Works
1. The client decrypts the file's key.
2. The client generates a URL: `https://boardly.studio/share/{share_id}#name={encodedName}&key={encodedKey}`.
3. The recipient opens the link. The browser downloads the encrypted blob, extracts the key from the URL fragment (`#key`), and decrypts the file directly in memory.

---
**Developer:** **Andrii Shumko** (SHAS Development) | 📍 Prague, Czech Republic  
*Building a future where privacy is a basic standard, not a premium feature.* **License:** [MIT License](LICENSE)

<br><br>
</div>

---

<div id="українська-версія-ua"></div>

## 🇺🇦 Українська версія

**FABY Cloud** — це ядро хмарного сховища з абсолютною приватністю, частина екосистеми [FABY](https://faby.world) / SHAS Development. 

Цей репозиторій містить **клієнтську частину (Flutter)** для роботи з віртуальною файловою системою (VFS) та криптографією, а також **публічні роути бекенду (FastAPI)**. Ми відкрили цей код, щоб довести прозорість нашої інфраструктури та гарантувати дотримання принципів **Zero-Knowledge (ZK)**.

### 📖 Чому цей код відкритий? (Partial Open Source)

Головне правило Zero-Knowledge: *"Серверу не можна довіряти"*. 
Ми відкрили ключові модулі сховища, щоб будь-який розробник або фахівець з кібербезпеки міг переконатися:
1. **Наш бекенд абсолютно "сліпий"**: Сервер оперує лише знеособленими UUID та зашифрованими байтами. Він ніколи не бачить ваших паролів, ключів розшифрування або навіть назв файлів.
2. **Шифрування відбувається виключно на клієнті**: Дані шифруються до того, як вони покинуть ваш пристрій.
3. **Пряме завантаження (Direct-to-Cloud)**: Ми не пропускаємо трафік файлів через наш бекенд. Натомість ми генеруємо AWS S3 Presigned URLs для прямого завантаження у Cloudflare R2.

> **Примітка:** Роути авторизації, білінгу (Stripe) та внутрішня бізнес-логіка залишаються закритими для захисту інфраструктури від зловживань. Цей репозиторій фокусується виключно на **Security & Storage Engine**.

### 🔐 Архітектура шифрування (3 рівні)

FABY Cloud використовує потужне багаторівневе шифрування на базі **AES-256-GCM**.

1. **Рівень Файлу (File Level)**
   Кожен файл шифрується унікальним випадковим ключем (`rawFileKey`) потоково (Stream Encryption). Файли більші за 100 МБ розбиваються на чанки по 50 МБ і завантажуються через Multipart Upload.
2. **Рівень Метаданих (Metadata Level)**
   Ключ файлу (`rawFileKey`) шифрується **Майстер-ключем користувача** (`userMasterKey`). У хмару відправляється лише зашифрований ключ (`encryptedFileKey`), а назва файлу ховається всередині зашифрованого JSON-вузла (VFS Node).
3. **Рівень Відновлення (Recovery Level)**
   Щоб не втратити Майстер-ключ при зміні пристрою, генерується **12-слівна секретна фраза** (BIP39). За допомогою `PBKDF2` (100,000 ітерацій) з неї генерується Key Encryption Key (KEK), яким шифрується Майстер-ключ для резервного копіювання в хмару. *Ми не маємо доступу до цієї фрази.*

### 🚀 Ключові можливості

- **Local-First VFS:** Віртуальна файлова система зберігається локально в базі даних SQLite (зашифровано). Метадані синхронізуються з хмарою за допомогою ETag.
- **Secure File Sharing:** При створенні публічного посилання ключ розшифрування вбудовується у **фрагмент URL** (`#key=...`), який ніколи не надсилається на сервер, забезпечуючи безпечний обмін (Client-Side Decryption).
- **Multipart Uploads:** Підтримка завантаження файлів об'ємом до 5 ГБ (обмеження платформи) з автоматичним відновленням завантаження чанків.
- **Корзина з захистом:** Видалені файли зберігаються 7 днів. Сервер підтримує безпечне відновлення без ризику перезапису актуальних даних.

### 🛠 Стек технологій

* **Клієнт:** Flutter / Dart, `cryptography` (AES-GCM), `bip39`, `sqflite` (VFS Cache), `flutter_secure_storage`.
* **Бекенд:** Python, FastAPI, SQLAlchemy (PostgreSQL), Boto3, Cloudflare R2 (S3 API).

### 💡 Демонстрація роботи Share-посилань
1. Клієнт розшифровує ключ файлу.
2. Клієнт генерує URL формату `https://boardly.studio/share/{share_id}#name={encodedName}&key={encodedKey}`.
3. Одержувач відкриває посилання. Браузер завантажує зашифрований файл через бекенд, бере ключ із URL-фрагмента (`#key`) і розшифровує файл безпосередньо в оперативній пам'яті клієнта.

---
**Розробник:** **Andrii Shumko** (SHAS Development) | 📍 Прага, Чехія  
*Будуємо майбутнє, де приватність — це базовий стандарт, а не преміум-функція.* **Ліцензія:** [MIT License](LICENSE)