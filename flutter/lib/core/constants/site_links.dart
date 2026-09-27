/// The project's public web pages.
///
/// These moved off the `web.nymchat.app/static/*.html` paths onto the apex
/// domain as clean slugs (`nymchat.app/dmca/`), so they live in one place here
/// rather than as literals scattered across the modals that link to them.
///
/// The slugs are the ones nym-web actually publishes — its `pages/<slug>.html`
/// filenames — NOT the old static filenames. `pp.html` became `/privacy/`, and
/// `tos.html` is now `/terms/`.
library;

/// Apex domain serving the public pages. NOT the app/API host — that stays
/// `web.nymchat.app` (see `ApiConfig.apiHost`), which is a different thing.
const String kSiteBase = 'https://nymchat.app';

const String kDocsUrl = '$kSiteBase/docs/';
const String kTermsUrl = '$kSiteBase/terms/';
const String kPrivacyUrl = '$kSiteBase/privacy/';
const String kDmcaUrl = '$kSiteBase/dmca/';

/// Public source repository.
const String kGithubUrl = 'https://github.com/Spl0itable/NYM';
