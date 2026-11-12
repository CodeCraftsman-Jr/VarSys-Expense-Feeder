import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../account/account_providers.dart';
import '../../core/theme/icons.dart';
import '../../core/theme/palette.dart';
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
  String? _error;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  String? _validate() {
    if (!RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(_email.text.trim())) return 'Enter your email address.';
    if (_password.text.isEmpty) return 'Enter your password.';
    return null;
  }

  Future<void> _submit() async {
    final invalid = _validate();
    if (invalid != null) return setState(() => _error = invalid);
    setState(() {
      _busy = true;
      _error = null;
    });
    final error = await ref.read(accountProvider.notifier).signIn(email: _email.text, password: _password.text);
    if (!mounted) return;
    if (error == null) {
      // The router's sign-in gate moves on to onboarding or the app by itself.
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
    return Scaffold(
      appBar: AppBar(title: const Text('Sign in to MoneyTrail'), automaticallyImplyLeading: false),
      body: AutofillGroup(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
          children: [
            if (notice != null) ...[
              Text(notice, style: context.text.bodyMedium?.copyWith(color: Palette.amber)),
              const SizedBox(height: 12),
            ],
            Text(
              'MoneyTrail works with your Joint Journey team, so sign in first. '
              'Use the VarSys account you use for Joint Journey. '
              'Your password goes only to the VarSys sign-in server.',
              style: context.text.bodyMedium?.copyWith(color: context.colors.onSurfaceVariant),
            ),
            const SizedBox(height: 20),
            TextField(
              controller: _email,
              enabled: !_busy,
              keyboardType: TextInputType.emailAddress,
              textInputAction: TextInputAction.next,
              autocorrect: false,
              autofillHints: const [AutofillHints.email, AutofillHints.username],
              decoration: const InputDecoration(labelText: 'Email', prefixIcon: Icon(PhosphorIconsBold.at)),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _password,
              enabled: !_busy,
              obscureText: _obscure,
              autocorrect: false,
              enableSuggestions: false,
              textInputAction: TextInputAction.done,
              autofillHints: const [AutofillHints.password],
              onSubmitted: (_) => _busy ? null : _submit(),
              decoration: InputDecoration(
                labelText: 'Password',
                prefixIcon: const Icon(PhosphorIconsBold.key),
                suffixIcon: IconButton(
                  tooltip: _obscure ? 'Show password' : 'Hide password',
                  onPressed: () => setState(() => _obscure = !_obscure),
                  icon: Icon(_obscure ? PhosphorIconsBold.eye : PhosphorIconsBold.eyeSlash),
                ),
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(_error!, style: context.text.bodySmall?.copyWith(color: Palette.coral)),
            ],
            const SizedBox(height: 20),
            FilledButton(
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(46)),
              onPressed: _busy ? null : _submit,
              child: _busy
                  ? const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('Sign in'),
            ),
            const SizedBox(height: 16),
            Text(
              'No account yet, or forgot your password? Use Joint Journey on the web, then sign in here.',
              style: context.text.bodySmall?.copyWith(color: context.colors.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}
