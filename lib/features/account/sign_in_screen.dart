import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../account/account_providers.dart';
import '../../core/theme/icons.dart';
import '../../core/theme/palette.dart';
import '../../ui/brand_mark.dart';
import '../../ui/widgets.dart';

/// Sign in with the VarSys account used for Joint Journey.
class SignInScreen extends ConsumerStatefulWidget {
  const SignInScreen({super.key});

  @override
  ConsumerState<SignInScreen> createState() => _SignInScreenState();
}

class _SignInScreenState extends ConsumerState<SignInScreen> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  var _obscure = true;
  var _busy = false;
  String? _emailError;
  String? _passwordError;
  String? _error;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  /// Checks both fields and shows each problem next to its own field.
  bool _validate() {
    final emailOk = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(_email.text.trim());
    final passwordOk = _password.text.isNotEmpty;
    setState(() {
      _emailError = emailOk ? null : 'Enter your email address.';
      _passwordError = passwordOk ? null : 'Enter your password.';
    });
    return emailOk && passwordOk;
  }

  Future<void> _submit() async {
    if (!_validate()) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _busy = true;
      _error = null;
    });
    final error = await ref.read(accountProvider.notifier).signIn(email: _email.text, password: _password.text);
    if (!mounted) return;
    if (error == null) {
      // Lets the phone offer to save the password. The router's sign-in gate moves on by itself.
      TextInput.finishAutofillContext();
      final name = ref.read(accountProvider).profile?.name;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(name == null || name.isEmpty ? 'Signed in' : 'Signed in as $name')),
      );
      return;
    }
    setState(() {
      _busy = false;
      _error = error;
    });
  }

  @override
  Widget build(BuildContext context) {
    final notice = ref.watch(accountProvider.select((s) => s.notice));
    final muted = context.colors.onSurfaceVariant;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 24, 24, 24),
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: AutofillGroup(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (notice != null) ...[
                      _Banner(icon: PhosphorIconsFill.info, color: Palette.amber, text: notice),
                      const SizedBox(height: 20),
                    ],
                    const Align(alignment: Alignment.centerLeft, child: BrandMark(size: 64)),
                    const SizedBox(height: 24),
                    Text('Sign in', style: context.text.headlineMedium?.copyWith(fontWeight: FontWeight.w700)),
                    const SizedBox(height: 8),
                    Text(
                      'Use your Joint Journey account. MoneyTrail sends your bank alerts to your team there.',
                      style: context.text.bodyLarge?.copyWith(color: muted, height: 1.4),
                    ),
                    const SizedBox(height: 28),
                    TextField(
                      controller: _email,
                      enabled: !_busy,
                      keyboardType: TextInputType.emailAddress,
                      textInputAction: TextInputAction.next,
                      autocorrect: false,
                      autofillHints: const [AutofillHints.email, AutofillHints.username],
                      onChanged: (_) {
                        if (_emailError != null) setState(() => _emailError = null);
                      },
                      decoration: InputDecoration(
                        labelText: 'Email',
                        errorText: _emailError,
                        prefixIcon: const Icon(PhosphorIconsBold.at),
                      ),
                    ),
                    const SizedBox(height: 14),
                    TextField(
                      controller: _password,
                      enabled: !_busy,
                      obscureText: _obscure,
                      autocorrect: false,
                      enableSuggestions: false,
                      textInputAction: TextInputAction.done,
                      autofillHints: const [AutofillHints.password],
                      onSubmitted: (_) => _busy ? null : _submit(),
                      onChanged: (_) {
                        if (_passwordError != null) setState(() => _passwordError = null);
                      },
                      decoration: InputDecoration(
                        labelText: 'Password',
                        errorText: _passwordError,
                        prefixIcon: const Icon(PhosphorIconsBold.key),
                        suffixIcon: IconButton(
                          tooltip: _obscure ? 'Show password' : 'Hide password',
                          onPressed: () => setState(() => _obscure = !_obscure),
                          icon: Icon(_obscure ? PhosphorIconsBold.eye : PhosphorIconsBold.eyeSlash),
                        ),
                      ),
                    ),
                    if (_error != null) ...[
                      const SizedBox(height: 16),
                      _Banner(icon: PhosphorIconsFill.warningCircle, color: Palette.red, text: _error!),
                    ],
                    const SizedBox(height: 24),
                    FilledButton(
                      // Stays readable while it waits: the default disabled look fades the label away.
                      style: FilledButton.styleFrom(
                        minimumSize: const Size.fromHeight(52),
                        disabledBackgroundColor: context.colors.primary.withValues(alpha: 0.75),
                        disabledForegroundColor: context.colors.onPrimary,
                      ),
                      onPressed: _busy ? null : _submit,
                      child: _busy
                          ? Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                SizedBox.square(
                                  dimension: 18,
                                  child: CircularProgressIndicator(strokeWidth: 2, color: context.colors.onPrimary),
                                ),
                                const SizedBox(width: 12),
                                const Text('Signing in…'),
                              ],
                            )
                          : const Text('Sign in'),
                    ),
                    const SizedBox(height: 24),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(PhosphorIconsRegular.shieldCheck, size: 18, color: muted),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            'Your password goes only to the VarSys sign-in server.',
                            style: context.text.bodySmall?.copyWith(color: muted),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Text(
                      'Forgot your password? Reset it on the Joint Journey sign-in page on the web. '
                      'New here? Ask your team alpha to invite you.',
                      style: context.text.bodySmall?.copyWith(color: muted, height: 1.4),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A short message with an icon, tinted by what it means. Read out as soon as it appears.
class _Banner extends StatelessWidget {
  const _Banner({required this.icon, required this.color, required this.text});

  final IconData icon;
  final Color color;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      liveRegion: true,
      container: true,
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(color: color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(14)),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: color, size: 22),
            const SizedBox(width: 12),
            Expanded(child: Text(text, style: context.text.bodyMedium)),
          ],
        ),
      ),
    );
  }
}
