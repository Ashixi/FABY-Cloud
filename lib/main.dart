import 'dart:convert';
import 'package:flutter/material.dart';

import 'package:faby/storage/auth_storage.dart';
import 'package:faby/services/auth_http_client.dart';
import 'package:faby/screens/cloud_storage_screen.dart';
import 'package:faby/models/user_data.dart';
import 'translations.dart';

// MARK: - ENTRY POINT
void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final String? token = await AuthStorage.getAccessToken();
  final bool isLoggedIn = token != null;

  runApp(BoardlyCloudApp(isLoggedIn: isLoggedIn));
}

// MARK: - MAIN APP WIDGET
class BoardlyCloudApp extends StatelessWidget {
  final bool isLoggedIn;

  const BoardlyCloudApp({super.key, required this.isLoggedIn});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Locale>(
      valueListenable: appLocale,
      builder: (context, locale, child) {
        return MaterialApp(
          title: 'FABY Cloud',
          debugShowCheckedModeBanner: false,
          locale: locale,
          theme: ThemeData(
            useMaterial3: true,
            colorScheme: ColorScheme.fromSeed(
              seedColor: const Color(0xFF009688),
              brightness: Brightness.light,
            ),
          ),
          home: isLoggedIn ? const CloudStorageScreen() : const AuthScreen(),
        );
      },
    );
  }
}

// MARK: - AUTH SCREEN
class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key});

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  // MARK: - STATE & DEPENDENCIES
  final _httpClient = AuthHttpClient();
  bool _isLoading = false;

  // MARK: - HELPERS
  void _showError(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _handleAuthSuccess(
    String accessToken,
    String refreshToken,
  ) async {
    await AuthStorage.saveTokens(accessToken, refreshToken);
    try {
      final response = await _httpClient.request(
        Uri.parse('https://api.boardly.studio/user/me'),
      );
      if (response.statusCode == 200) {
        final userDataJson = jsonDecode(response.body);
        final userData = UserData.fromJson(userDataJson);
        await AuthStorage.saveUserData(userData);

        if (mounted) {
          Navigator.of(context).pushReplacement(
            MaterialPageRoute(builder: (_) => const CloudStorageScreen()),
          );
        }
      } else {
        _showError(
          '${tr(context, 'profile_error')} (Code: ${response.statusCode})',
        );
      }
    } catch (e) {
      _showError(tr(context, 'profile_error'));
    }
  }

  Future<void> _resendCode(String email) async {
    if (email.isEmpty) {
      _showError(tr(context, 'email_required') ?? 'Email required');
      return;
    }

    setState(() => _isLoading = true);
    try {
      final response = await _httpClient.request(
        Uri.parse("https://api.boardly.studio/auth/request-confirmation"),
        method: 'POST',
        headers: {"Content-Type": "application/json"},
        body: jsonEncode({'email': email}),
      );

      if (response.statusCode == 200) {
        _showError(tr(context, 'code_sent'));
      } else {
        _showError(
          "${tr(context, 'auth_error')} ${jsonDecode(response.body)['detail']}",
        );
      }
    } catch (e) {
      _showError("${tr(context, 'network_error')} $e");
    } finally {
      setState(() => _isLoading = false);
    }
  }

  // MARK: - LOGIN FLOW
  void _showLoginDialog() {
    final emailController = TextEditingController();
    final passwordController = TextEditingController();

    showDialog(
      context: context,
      builder:
          (ctx) => AlertDialog(
            title: Text(tr(context, 'login')),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: emailController,
                  decoration: InputDecoration(
                    labelText: tr(context, 'email'),
                    prefixIcon: const Icon(Icons.email),
                  ),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: passwordController,
                  decoration: InputDecoration(
                    labelText: tr(context, 'password'),
                    prefixIcon: const Icon(Icons.lock),
                  ),
                  obscureText: true,
                ),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                    onPressed: () {
                      Navigator.pop(ctx);
                      _showForgotPasswordDialog(emailController.text.trim());
                    },
                    child: Text(
                      tr(context, 'forgot_password') ?? 'Forgot password?',
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: Text(tr(context, 'cancel')),
              ),
              FilledButton(
                onPressed: () async {
                  final email = emailController.text.trim();
                  final password = passwordController.text;
                  if (email.isEmpty || password.isEmpty) return;

                  setState(() => _isLoading = true);

                  try {
                    final response = await _httpClient.request(
                      Uri.parse(
                        "https://api.boardly.studio/auth/request-confirmation",
                      ),
                      method: 'POST',
                      headers: {"Content-Type": "application/json"},
                      body: jsonEncode({'email': email}),
                    );

                    if (response.statusCode == 200) {
                      if (mounted) Navigator.pop(ctx);
                      _showCodeVerificationDialog(email, password);
                    } else {
                      _showError(
                        "${tr(context, 'auth_error')} ${jsonDecode(response.body)['detail']}",
                      );
                    }
                  } catch (e) {
                    _showError("${tr(context, 'network_error')} $e");
                  } finally {
                    setState(() => _isLoading = false);
                  }
                },
                child: Text(tr(context, 'login')),
              ),
            ],
          ),
    );
  }

  void _showForgotPasswordDialog(String initialEmail) {
    final emailController = TextEditingController(text: initialEmail);
    final codeController = TextEditingController();
    final newPasswordController = TextEditingController();
    bool isCodeSent = false;

    showDialog(
      context: context,
      builder:
          (ctx) => StatefulBuilder(
            builder: (context, setDialogState) {
              return AlertDialog(
                title: Text(tr(context, 'reset_password') ?? 'Reset Password'),
                content: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (!isCodeSent)
                      TextField(
                        controller: emailController,
                        decoration: InputDecoration(
                          labelText: tr(context, 'email'),
                          prefixIcon: const Icon(Icons.email),
                        ),
                      )
                    else ...[
                      TextField(
                        controller: codeController,
                        decoration: InputDecoration(
                          labelText: tr(context, 'code_hint'),
                        ),
                        keyboardType: TextInputType.number,
                      ),
                      const SizedBox(height: 16),
                      TextField(
                        controller: newPasswordController,
                        decoration: InputDecoration(
                          labelText:
                              tr(context, 'new_password') ?? 'New password',
                        ),
                        obscureText: true,
                      ),
                      const SizedBox(height: 8),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton(
                          onPressed:
                              () => _resendCode(emailController.text.trim()),
                          child: Text(
                            tr(context, 'resend_code') ?? 'Resend code',
                            style: const TextStyle(fontSize: 12),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(ctx),
                    child: Text(tr(context, 'cancel')),
                  ),
                  FilledButton(
                    onPressed: () async {
                      final email = emailController.text.trim();
                      if (email.isEmpty) return;

                      if (!isCodeSent) {
                        setState(() => _isLoading = true);
                        try {
                          final response = await _httpClient.request(
                            Uri.parse(
                              'https://api.boardly.studio/auth/request-confirmation',
                            ),
                            method: 'POST',
                            headers: {'Content-Type': 'application/json'},
                            body: jsonEncode({'email': email}),
                          );
                          if (response.statusCode == 200) {
                            setDialogState(() => isCodeSent = true);
                            _showError(tr(context, 'code_sent'));
                          } else {
                            _showError(
                              "${tr(context, 'error')} ${jsonDecode(response.body)['detail']}",
                            );
                          }
                        } catch (e) {
                          _showError("${tr(context, 'network_error')} $e");
                        } finally {
                          setState(() => _isLoading = false);
                        }
                      } else {
                        final code = codeController.text.trim();
                        final newPassword = newPasswordController.text;
                        if (code.isEmpty || newPassword.isEmpty) return;

                        setState(() => _isLoading = true);
                        try {
                          final response = await _httpClient.request(
                            Uri.parse(
                              'https://api.boardly.studio/auth/reset-password',
                            ),
                            method: 'POST',
                            headers: {'Content-Type': 'application/json'},
                            body: jsonEncode({
                              'email': email,
                              'code': code,
                              'new_password': newPassword,
                            }),
                          );

                          if (response.statusCode == 200) {
                            Navigator.pop(ctx);
                            _showError(
                              tr(context, 'success') ??
                                  'Password successfully changed',
                            );
                          } else {
                            _showError(
                              "${tr(context, 'error')} ${jsonDecode(response.body)['detail']}",
                            );
                          }
                        } catch (e) {
                          _showError("${tr(context, 'network_error')} $e");
                        } finally {
                          setState(() => _isLoading = false);
                        }
                      }
                    },
                    child: Text(
                      isCodeSent
                          ? tr(context, 'confirm')
                          : tr(context, 'get_code'),
                    ),
                  ),
                ],
              );
            },
          ),
    );
  }

  Future<void> _showCodeVerificationDialog(
    String email,
    String password,
  ) async {
    final codeController = TextEditingController();

    await showDialog(
      context: context,
      barrierDismissible: false,
      builder:
          (ctx) => AlertDialog(
            title: Text(tr(context, 'code_title')),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: codeController,
                  decoration: InputDecoration(
                    labelText: tr(context, 'code_hint'),
                  ),
                  keyboardType: TextInputType.number,
                ),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton(
                    onPressed: () => _resendCode(email),
                    child: Text(
                      tr(context, 'resend_code') ?? 'Resend code',
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: Text(tr(context, 'cancel')),
              ),
              ElevatedButton(
                onPressed: () {
                  if (codeController.text.isEmpty) return;
                  Navigator.pop(ctx);
                  _completeLogin(email, password, codeController.text.trim());
                },
                child: Text(tr(context, 'confirm')),
              ),
            ],
          ),
    );
  }

  Future<void> _completeLogin(
    String email,
    String password,
    String code,
  ) async {
    setState(() => _isLoading = true);

    try {
      final response = await _httpClient.request(
        Uri.parse("https://api.boardly.studio/auth/login"),
        method: 'POST',
        headers: {"Content-Type": "application/json"},
        body: jsonEncode({
          "data": {"email": email, "password": password, "email_code": code},
          "device_id": "boardly_drive_client",
        }),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        await _handleAuthSuccess(data['access_token'], data['refresh_token']);
      } else {
        _showError(
          "${tr(context, 'auth_error')} ${jsonDecode(response.body)['detail']}",
        );
      }
    } catch (e) {
      _showError("${tr(context, 'network_error')} $e");
    } finally {
      setState(() => _isLoading = false);
    }
  }

  // MARK: - REGISTRATION FLOW
  void _showRegistrationDialog() {
    final usernameController = TextEditingController();
    final emailController = TextEditingController();
    final passwordController = TextEditingController();
    final codeController = TextEditingController();

    bool isCodeSent = false;
    bool isAgreedToTerms = false;

    showDialog(
      context: context,
      builder:
          (ctx) => StatefulBuilder(
            builder: (context, setDialogState) {
              return AlertDialog(
                title: Text(tr(context, 'register')),
                content: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (!isCodeSent) ...[
                        TextField(
                          controller: usernameController,
                          decoration: InputDecoration(
                            labelText: tr(context, 'name'),
                          ),
                        ),
                        const SizedBox(height: 16),
                        TextField(
                          controller: emailController,
                          decoration: InputDecoration(
                            labelText: tr(context, 'email'),
                          ),
                        ),
                        const SizedBox(height: 16),
                        TextField(
                          controller: passwordController,
                          decoration: InputDecoration(
                            labelText: tr(context, 'password'),
                          ),
                          obscureText: true,
                        ),
                        const SizedBox(height: 16),
                        Row(
                          children: [
                            Checkbox(
                              value: isAgreedToTerms,
                              onChanged:
                                  (val) => setDialogState(
                                    () => isAgreedToTerms = val ?? false,
                                  ),
                            ),
                            Expanded(
                              child: GestureDetector(
                                onTap: _showTermsDialog,
                                child: Text(
                                  tr(context, 'I agree to Terms') ??
                                      'I agree to Terms',
                                  style: const TextStyle(
                                    fontSize: 12,
                                    decoration: TextDecoration.underline,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ] else ...[
                        TextField(
                          controller: codeController,
                          decoration: InputDecoration(
                            labelText: tr(context, 'code_title'),
                          ),
                          keyboardType: TextInputType.number,
                        ),
                        const SizedBox(height: 8),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: TextButton(
                            onPressed:
                                () => _resendCode(emailController.text.trim()),
                            child: Text(
                              tr(context, 'resend_code') ?? 'Resend code',
                              style: const TextStyle(fontSize: 12),
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(ctx),
                    child: Text(tr(context, 'cancel')),
                  ),
                  FilledButton(
                    onPressed:
                        (!isCodeSent && !isAgreedToTerms)
                            ? null
                            : () async {
                              if (!isCodeSent) {
                                setState(() => _isLoading = true);
                                try {
                                  final response = await _httpClient.request(
                                    Uri.parse(
                                      'https://api.boardly.studio/auth/request-confirmation',
                                    ),
                                    method: 'POST',
                                    headers: {
                                      'Content-Type': 'application/json',
                                    },
                                    body: jsonEncode({
                                      'email': emailController.text.trim(),
                                    }),
                                  );

                                  if (response.statusCode == 200) {
                                    setDialogState(() => isCodeSent = true);
                                  } else {
                                    _showError(
                                      "${tr(context, 'auth_error')} ${jsonDecode(response.body)['detail']}",
                                    );
                                  }
                                } catch (e) {
                                  _showError(
                                    "${tr(context, 'network_error')} $e",
                                  );
                                } finally {
                                  setState(() => _isLoading = false);
                                }
                              } else {
                                setState(() => _isLoading = true);
                                try {
                                  final response = await _httpClient.request(
                                    Uri.parse(
                                      "https://api.boardly.studio/auth/register",
                                    ),
                                    method: 'POST',
                                    headers: {
                                      "Content-Type": "application/json",
                                    },
                                    body: jsonEncode({
                                      "username":
                                          usernameController.text.trim(),
                                      "email": emailController.text.trim(),
                                      "password": passwordController.text,
                                      "email_code": codeController.text.trim(),
                                    }),
                                  );

                                  if (response.statusCode == 200 ||
                                      response.statusCode == 201) {
                                    if (mounted) Navigator.pop(ctx);
                                    _completeLogin(
                                      emailController.text.trim(),
                                      passwordController.text,
                                      codeController.text.trim(),
                                    );
                                  } else {
                                    _showError(
                                      "${tr(context, 'auth_error')} ${jsonDecode(response.body)['detail']}",
                                    );
                                  }
                                } catch (e) {
                                  _showError(
                                    "${tr(context, 'network_error')} $e",
                                  );
                                } finally {
                                  setState(() => _isLoading = false);
                                }
                              }
                            },
                    child: Text(
                      isCodeSent
                          ? (tr(context, 'finish') ?? 'Finish')
                          : (tr(context, 'get_code') ?? 'Get code'),
                    ),
                  ),
                ],
              );
            },
          ),
    );
  }

  // MARK: - TERMS & PRIVACY
  void _showTermsDialog() {
    final isUa = appLocale.value.languageCode == 'uk';

    final String termsTextEn = '''
Terms of Use and Privacy Policy of the FABY Ecosystem
Last updated: February 28, 2026

This document constitutes a legally binding agreement between you (the "User") and the developer of the FABY Ecosystem. By using the Boardly application and its integrated services (including FABY Cloud), you agree to the terms described below.

1. Account Registration and Security
To use Boardly and access the FABY Ecosystem, you must create an account using a valid email address. Registration and account recovery are performed via a one-time verification code sent to your email. You are responsible for maintaining the confidentiality of your account credentials.

2. Service Description
The FABY Ecosystem provides a suite of tools for collaboration and data storage:
• Boardly Collaboration (P2P): An online platform that allows users to work together on interactive boards. It uses peer-to-peer (WebRTC) technology to synchronize data directly. We do not store or inspect content transmitted directly between users during these live sessions.
• FABY Cloud: An integrated, secure cloud storage service for your files, projects, and backups, powering the Boardly application.

3. FABY Cloud & Zero-Knowledge Encryption
FABY Cloud is built on a "Zero-Knowledge" architecture to guarantee your absolute privacy.
• Client-Side Encryption: All files and virtual file system (VFS) nodes are encrypted locally on your device using AES-GCM 256-bit encryption before being uploaded to our servers.
• Master Key & Recovery: Your encryption keys are derived from a secret 12-word recovery phrase generated on your device. We do not have access to your raw recovery phrase or master key.
• Loss of Access: If you lose your recovery phrase and your device's local storage is cleared, your encrypted data will become permanently inaccessible. We cannot recover or reset your password/keys to decrypt your files.

4. Storage Limits, Trash, and Data Deletion
• Quotas: Storage usage is calculated based on the encrypted file sizes uploaded to FABY Cloud. 
• Trash Retention: Deleted files and folders are moved to a Trash folder. They are retained for 7 days before being permanently and irreversibly deleted.
• Account Deletion: You may delete your account at any time. Upon deletion, all associated cloud data and account information are permanently removed.

5. Privacy Policy and Data Processing
We minimize data collection to provide a secure service.
• Personal Data: We store your email address, username, public user identifier, and a securely hashed password.
• Cloud Storage Data: Your encrypted files are securely stored using Cloudflare R2 infrastructure. Because the data is end-to-end encrypted, we cannot see the contents, names, or types of your files.
• Shared Links: If you generate a public sharing link, the decryption key is embedded in the URL fragment (#key=...). This is processed strictly on the recipient's client side and is never sent to our backend.

6. Changes to These Terms
We may update these Terms at any time. Continued use of the Boardly application or FABY Cloud constitutes acceptance of the updated version.

Contact: support@boardly.studio
Developer: Andrii Shumko, Prague, Czech Republic
''';

    final String termsTextUa = '''
Умови використання та Політика конфіденційності екосистеми FABY
Останнє оновлення: 28 лютого 2026 року

Цей документ є юридичною угодою між вами («Користувач») та розробником екосистеми FABY. Використовуючи додаток Boardly та його інтегровані сервіси (включно з FABY Cloud), ви погоджуєтеся з умовами, описаними нижче.

1. Реєстрація акаунту та безпека
Щоб користуватися Boardly та отримати доступ до екосистеми FABY, ви повинні створити акаунт за допомогою дійсної електронної пошти. Реєстрація та відновлення акаунту здійснюються за допомогою одноразового коду. Ви несете відповідальність за збереження конфіденційності ваших облікових даних.

2. Опис сервісу
Екосистема FABY надає набір інструментів для співпраці та зберігання даних:
• Boardly Collaboration (P2P): Онлайн-платформа для спільної роботи на інтерактивних дошках. Використовує технологію WebRTC для прямої синхронізації даних. Ми не зберігаємо та не перевіряємо контент, що передається безпосередньо між користувачами.
• FABY Cloud: Інтегрований, безпечний сервіс хмарного зберігання ваших файлів, проєктів та резервних копій, що забезпечує роботу Boardly.

3. FABY Cloud та Zero-Knowledge шифрування
FABY Cloud побудовано на архітектурі "Zero-Knowledge", щоб гарантувати вашу абсолютну конфіденційність.
• Клієнтське шифрування: Усі файли та вузли віртуальної файлової системи шифруються локально на вашому пристрої за допомогою AES-GCM 256-bit перед завантаженням на наші сервери.
• Майстер-ключ та відновлення: Ваші ключі шифрування генеруються із секретної 12-слівної фрази відновлення (Seed). Ми не маємо доступу до вашої фрази або майстер-ключа.
• Втрата доступу: Якщо ви втратите фразу відновлення і локальне сховище вашого пристрою буде очищено, ваші дані стануть назавжди недоступними. Ми не можемо відновити ваш пароль або ключі.

4. Ліміти сховища, Кошик та Видалення даних
• Квоти: Використання сховища розраховується на основі розміру зашифрованих файлів, завантажених у FABY Cloud.
• Кошик: Видалені файли зберігаються в Кошику протягом 7 днів перед безповоротним видаленням.
• Видалення акаунту: Ви можете видалити свій акаунт у будь-який час. Всі пов'язані хмарні дані будуть назавжди видалені.

5. Політика конфіденційності та обробка даних
Ми мінімізуємо збір даних.
• Особисті дані: Ми зберігаємо ваш email, ім'я користувача та безпечно хешований пароль.
• Дані хмарного сховища: Ваші файли безпечно зберігаються на інфраструктурі Cloudflare R2. Оскільки вони мають наскрізне шифрування, ми не можемо бачити їхній вміст, назви чи типи.
• Посилання для доступу: Якщо ви генеруєте публічне посилання, ключ розшифрування вбудовується у фрагмент URL (#key=...). Це обробляється виключно на стороні клієнта і ніколи не надсилається на наш бекенд.

6. Зміни до цих Умов
Ми можемо оновлювати ці Умови у будь-який час. Подальше використання додатка Boardly або FABY Cloud означає згоду з оновленою версією.

Контакти: support@boardly.studio
Розробник: Andrii Shumko, Prague, Czech Republic
''';

    showDialog(
      context: context,
      builder:
          (ctx) => AlertDialog(
            title: Text(
              isUa
                  ? 'Умови та Політика конфіденційності'
                  : 'Terms of Use & Privacy Policy',
            ),
            content: SizedBox(
              width: double.maxFinite,
              child: Scrollbar(
                child: SingleChildScrollView(
                  child: Text(
                    isUa ? termsTextUa : termsTextEn,
                    style: const TextStyle(fontSize: 13, height: 1.4),
                  ),
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: Text(
                  tr(context, 'close') ?? (isUa ? 'Закрити' : 'Close'),
                ),
              ),
            ],
          ),
    );
  }

  // MARK: - UI COMPONENTS
  PopupMenuItem<String> _buildLanguageItem(
    String code,
    String flag,
    String name,
  ) {
    final bool isSelected = appLocale.value.languageCode == code;
    return PopupMenuItem<String>(
      value: code,
      child: Row(
        children: [
          Text(flag, style: const TextStyle(fontSize: 18)),
          const SizedBox(width: 12),
          Text(
            name,
            style: TextStyle(
              color: isSelected ? Theme.of(context).colorScheme.primary : null,
              fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
            ),
          ),
          if (isSelected) ...[
            const Spacer(),
            Icon(
              Icons.check,
              size: 16,
              color: Theme.of(context).colorScheme.primary,
            ),
          ],
        ],
      ),
    );
  }

  // MARK: - BUILD MAIN
  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Locale>(
      valueListenable: appLocale,
      builder: (context, locale, _) {
        return Scaffold(
          extendBodyBehindAppBar: true,
          appBar: AppBar(
            backgroundColor: Colors.transparent,
            elevation: 0,
            actions: [
              PopupMenuButton<String>(
                icon: const Icon(Icons.language, color: Colors.white),
                tooltip: 'Language',
                onSelected: (String langCode) {
                  appLocale.value = Locale(langCode);
                },
                itemBuilder:
                    (BuildContext context) => <PopupMenuEntry<String>>[
                      _buildLanguageItem('uk', '🇺🇦', 'Українська'),
                      _buildLanguageItem('en', '🇺🇸', 'English'),
                      _buildLanguageItem('de', '🇩🇪', 'Deutsch'),
                    ],
              ),
              const SizedBox(width: 8),
            ],
          ),
          body: Container(
            width: double.infinity,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Colors.teal.shade800, Colors.teal.shade500],
              ),
            ),
            child: Center(
              child: Card(
                elevation: 12,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(28),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(40.0),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        Icons.cloud_queue_rounded,
                        size: 64,
                        color: Color(0xFF009688),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        tr(context, 'app_title'),
                        style: const TextStyle(
                          fontSize: 28,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        tr(context, 'app_subtitle'),
                        style: const TextStyle(color: Colors.grey),
                      ),
                      const SizedBox(height: 40),
                      if (_isLoading)
                        const CircularProgressIndicator()
                      else ...[
                        SizedBox(
                          width: 250,
                          height: 50,
                          child: FilledButton(
                            onPressed: _showLoginDialog,
                            child: Text(tr(context, 'login')),
                          ),
                        ),
                        const SizedBox(height: 12),
                        TextButton(
                          onPressed: _showRegistrationDialog,
                          child: Text(tr(context, 'no_account')),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
