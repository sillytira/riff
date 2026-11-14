"""Standalone media extraction. No subprocesses, web service or insecure TLS override."""
import json
import os
import re
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
                webpageURL=webpage, artworkURL=info.get('thumbnail') or next((item.get('url') for item in reversed(info.get('thumbnails') or []) if item.get('url')), None),
                duration=info.get('duration'), provider=info.get('extractor_key') or info.get('ie_key') or '', album=info.get('album'))


def media_url(value):
    parsed = urllib.parse.urlparse(value)
    if parsed.scheme not in ('https', 'http') or not parsed.hostname:
        raise ValueError('Enter a valid HTTP or HTTPS media URL.')
    return value


def music_tracks(response):
    def renderers(value):
        if isinstance(value, dict):
            if 'musicResponsiveListItemRenderer' in value:
                yield value['musicResponsiveListItemRenderer']
            else:
                for child in value.values():
                    yield from renderers(child)
        elif isinstance(value, list):
            for child in value:
                yield from renderers(child)

    found = []
    seen = set()
    for renderer in renderers(response):
        columns = renderer.get('flexColumns', [])
        def runs(index):
            if index >= len(columns):
                return []
            return columns[index].get('musicResponsiveListItemFlexColumnRenderer', {}).get('text', {}).get('runs', [])
        overlay = renderer.get('overlay', {}).get('musicItemThumbnailOverlayRenderer', {}).get('content', {}).get('musicPlayButtonRenderer', {})
        video_id = renderer.get('playlistItemData', {}).get('videoId') or overlay.get('playNavigationEndpoint', {}).get('watchEndpoint', {}).get('videoId')
        if not video_id or not re.fullmatch(r'[A-Za-z0-9_-]{11}', video_id) or video_id in seen:
            continue
        title = ''.join(run.get('text', '') for run in runs(0)).strip()
        if not title:
            continue
        segments = [part.strip() for part in re.split(r'\s*[•·]\s*', ''.join(run.get('text', '') for run in runs(1)))]
        segments = [part for part in segments if part and part.lower() not in ('song', 'video')]
        duration = None
        if segments and re.fullmatch(r'\d+:\d{2}(?::\d{2})?', segments[-1]):
            duration = 0
            for component in segments.pop().split(':'):
                duration = duration * 60 + int(component)
        thumbnails = renderer.get('thumbnail', {}).get('musicThumbnailRenderer', {}).get('thumbnail', {}).get('thumbnails', [])
        artwork = thumbnails[-1].get('url') if thumbnails else f'https://i.ytimg.com/vi/{video_id}/hqdefault.jpg'
        found.append(dict(id=video_id, title=title, artist=segments[0] if segments else '',
                          album=segments[1] if len(segments) > 1 else None, duration=duration,
                          artworkURL=artwork, webpageURL=f'https://music.youtube.com/watch?v={video_id}', provider='YoutubeMusic'))
        seen.add(video_id)
    return found


def music_search(query):
    with yt_dlp.YoutubeDL(options()) as extractor:
        youtube = extractor.get_info_extractor('Youtube')
        youtube.initialize()
        response = youtube._call_api('search',
            {'query': query, 'params': 'EgWKAQIIAWoMEA4QChADEAQQCRAF'},
            video_id=query, default_client='web_music', api_hostname='music.youtube.com')
        return {'tracks': music_tracks(response)}


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
        if request.get('provider') == 'ytmusic' and not query.startswith(('http:', 'https:')):
            return music_search(query)
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
