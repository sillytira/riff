"""Standalone media extraction. No subprocesses, web service or insecure TLS override."""
import json
import os
import urllib.parse

import certifi
import yt_dlp

os.environ.setdefault('SSL_CERT_FILE', certifi.where())

# Supply yt-dlp's JS challenge protocol through Apple's in-process interpreter.
# Hash/version checking of the bundled EJS scripts remains in EJSBaseJCP.
try:
    import riff_native
except ImportError:
    riff_native = None  # Host-side unit tests use the same protocol with a fake extractor.

if riff_native is not None:
    from yt_dlp.extractor.youtube.jsc._builtin.ejs import EJSBaseJCP
    from yt_dlp.extractor.youtube.jsc.provider import register_provider, register_preference
    from yt_dlp.extractor.youtube.pot._provider import BuiltinIEContentProvider

    @register_provider
    class AppleJCP(EJSBaseJCP, BuiltinIEContentProvider):
        PROVIDER_NAME = 'apple'
        JS_RUNTIME_NAME = 'JavaScriptCore'

        def is_available(self):
            return self._available

        def _run_js_runtime(self, stdin):
            return riff_native.evaluate_js(stdin)

    @register_preference(AppleJCP)
    def apple_preference(provider, requests):
        return 10000


class Log:
    def debug(self, message):
        pass

    def warning(self, message):
        pass

    def error(self, message):
        pass


def options(**extra):
    trust = {'compat_opts': ['no-certifi']} if os.environ.get('SSL_CERT_FILE') != certifi.where() else {}
    return dict(**trust, quiet=True, no_warnings=True, logger=Log(), cachedir=False,
                socket_timeout=25, retries=2, noplaylist=True,
                check_formats=False, nocheckcertificate=False,
                format='bestaudio[ext=m4a]/bestaudio[ext=mp3]/best[ext=mp4]/bestaudio/best',
                **extra)


def track(info):
    identity = str(info.get('id') or info.get('url') or '')
    webpage = info.get('webpage_url') or info.get('original_url') or info.get('url') or ''
    if not webpage.startswith('http') and info.get('ie_key') in ('Youtube', 'YoutubeIE'):
        webpage = 'https://www.youtube.com/watch?v=' + identity
    return dict(id=identity, title=info.get('track') or info.get('title') or 'Untitled',
                artist=info.get('artist') or info.get('uploader') or info.get('channel') or '',
                webpageURL=webpage, artworkURL=info.get('thumbnail'),
                duration=info.get('duration'), provider=info.get('extractor_key') or info.get('ie_key') or '')


def media_url(value):
    parsed = urllib.parse.urlparse(value)
    if parsed.scheme not in ('https', 'http') or not parsed.hostname:
        raise ValueError('Enter a valid HTTP or HTTPS media URL.')
    return value


def dispatch(request):
    operation = request.get('operation')
    if operation == 'health':
        import ssl
        from yt_dlp.version import __version__
        result = dict(python=os.sys.version, extractor=__version__, tls=ssl.OPENSSL_VERSION,
                      javascript=riff_native is not None)
        if riff_native is not None:
            result['javascriptResult'] = riff_native.evaluate_js('console.log(JSON.stringify({answer: 6 * 7}))')
        return result
    if operation == 'search':
        query = str(request.get('query', '')).strip()
        if not query:
            return {'tracks': []}
        prefix = 'scsearch15:' if request.get('provider') == 'soundcloud' else 'ytsearch15:'
        target = media_url(query) if query.startswith(('http:', 'https:')) else prefix + query
        with yt_dlp.YoutubeDL(options(extract_flat='in_playlist', playlistend=30)) as extractor:
            info = extractor.extract_info(target, download=False)
            entries = info.get('entries', [info])
            return {'tracks': [track(entry) for entry in entries if entry]}
    if operation == 'resolve':
        with yt_dlp.YoutubeDL(options()) as extractor:
            info = extractor.extract_info(media_url(request['url']), download=False)
            return dict(track=track(info), streamURL=info['url'], headers=info.get('http_headers', {}),
                        ext=info.get('ext'), protocol=info.get('protocol'))
    if operation == 'playlist':
        opts = options(extract_flat='in_playlist', playlistend=1000)
        opts['noplaylist'] = False
        with yt_dlp.YoutubeDL(opts) as extractor:
            info = extractor.extract_info(media_url(request['url']), download=False)
            return dict(title=info.get('title', 'Imported playlist'),
                        tracks=[track(entry) for entry in info.get('entries', [info]) if entry])
    raise ValueError('Unsupported media operation.')


def dispatch_json(payload):
    try:
        return json.dumps(dispatch(json.loads(payload)), ensure_ascii=False)
    except Exception as error:
        return json.dumps({'error': str(error)}, ensure_ascii=False)
