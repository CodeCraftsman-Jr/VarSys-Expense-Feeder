/// Where the app may go, in order: sign in first, then onboarding, then the
/// app. Every route, including notification taps, share intents and deep
/// links, passes through this. Returns the location to redirect to, or null
/// to stay.
///
/// [signedIn] comes from the cached profile, so a signed-in member keeps
/// using the app offline; only an explicit sign-out or an ended session
/// (two 401s) sends them back here.
String? gateRedirect({required String location, required bool signedIn, required bool onboarded}) {
  if (!signedIn) return location == signInPath ? null : signInPath;
  if (location == signInPath) return onboarded ? '/' : '/welcome';
  if (!onboarded && location != '/welcome') return '/welcome';
  if (onboarded && location == '/welcome') return '/';
  return null;
}

const signInPath = '/account/sign-in';
