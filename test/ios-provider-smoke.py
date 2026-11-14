"""Live provider checks on the macOS runner. Reports never include signed stream URLs."""
import json
import pathlib
import re
import sys
import urllib.parse
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'ios' / 'PythonApp'))
import riff_backend

_original_options = riff_backend.options


def host_options(**extra):
    options = _original_options(**extra)
    # This host check uses Node; native iOS uses the separately tested JSC bridge.
    options.update(js_runtimes={'node': {}}, socket_timeout=15, retries=1)
    return options


riff_backend.options = host_options


def read(url, headers, maximum=65536):
    request = urllib.request.Request(url, headers={**headers, 'Range': f'bytes=0-{maximum-1}'})
    with urllib.request.urlopen(request, timeout=30) as response:
        if response.status not in (200, 206):
            raise RuntimeError(f'Media request returned HTTP {response.status}')
        data = response.read(maximum)
    if not data:
        raise RuntimeError('Media request returned no audio data')
    return data


def check(provider):
    report = {'provider': provider, 'passed': False, 'stage': 'search'}
    try:
        result = riff_backend.dispatch({'operation': 'search', 'provider': provider, 'query': 'Beethoven Moonlight Sonata'})
        tracks = [track for track in result['tracks'] if track['webpageURL']]
        if not tracks:
            raise RuntimeError('Provider search returned no tracks')
        report['searchCount'] = len(tracks)
        report['stage'] = 'resolve'
        errors = []
        media = None
        for track in tracks[:3]:
            try:
                media = riff_backend.dispatch({'operation': 'resolve', 'url': track['webpageURL']})
                break
            except Exception as error:
                errors.append(str(error))
        if media is None:
            raise RuntimeError('; '.join(errors))
        report['format'] = media.get('ext')
        report['transport'] = media.get('protocol')
        report['stage'] = 'media'
        url = media['streamURL']
        data = read(url, media['headers'])
        if 'm3u8' in (media.get('protocol') or ''):
            for _ in range(3):
                text = data.decode('utf-8-sig')
                if not text.startswith('#EXTM3U'):
                    raise RuntimeError('Expected a playable HLS playlist')
                entries = [line.strip() for line in text.splitlines() if line.strip() and not line.startswith('#')]
                if not entries:
                    raise RuntimeError('HLS playlist did not contain media')
                url = urllib.parse.urljoin(url, entries[0])
                data = read(url, media['headers'])
                if not data.startswith(b'#EXTM3U'):
                    break
            else:
                raise RuntimeError('HLS playlist nesting exceeded the check limit')
        report.update(passed=True, stage='complete', mediaBytesChecked=len(data))
    except Exception as error:
        # Avoid publishing CDN signatures, cookies or authorization in CI reports.
        report['error'] = re.sub(r'https?://\S+', '<provider-url>', str(error))[:2000]
    return report


reports = [check('youtube'), check('soundcloud')]
output = ROOT / 'provider-results.json'
output.write_text(json.dumps({'checks': reports}, indent=2) + '\n')
print(output.read_text())
sys.exit(0 if all(report['passed'] for report in reports) else 1)
