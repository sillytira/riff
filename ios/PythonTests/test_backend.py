import json
import unittest
from unittest.mock import patch
import riff_backend as backend


class FakeExtractor:
    def __init__(self, options):
        self.options = options
    def __enter__(self):
        return self
    def __exit__(self, *args):
        pass
    def extract_info(self, target, download):
        if target.startswith('ytsearch'):
            return {'entries': [{'id': 'test', 'title': 'Song', 'url': 'https://youtube.com/watch?v=test', 'ie_key': 'Youtube'}]}
        return {'id': 'test', 'title': 'Song', 'url': 'https://cdn.example.com/song.m4a', 'ext': 'm4a', 'http_headers': {'User-Agent': 'Riff'}}


class BackendTests(unittest.TestCase):
    def test_empty_search_does_not_construct_extractor(self):
        with patch.object(backend.yt_dlp, 'YoutubeDL') as factory:
            self.assertEqual(backend.dispatch({'operation': 'search', 'query': ''}), {'tracks': []})
            factory.assert_not_called()

    def test_search_and_resolve_use_same_json_contract(self):
        with patch.object(backend.yt_dlp, 'YoutubeDL', FakeExtractor):
            search = backend.dispatch({'operation': 'search', 'query': 'Song'})
            self.assertEqual(search['tracks'][0]['title'], 'Song')
            resolved = backend.dispatch({'operation': 'resolve', 'url': 'https://youtube.com/watch?v=test'})
            self.assertEqual(resolved['streamURL'], 'https://cdn.example.com/song.m4a')
            self.assertEqual(resolved['headers']['User-Agent'], 'Riff')

    def test_youtube_music_metadata_duration_unicode_and_deduplication(self):
        renderer = {'musicResponsiveListItemRenderer': {
            'playlistItemData': {'videoId': 'abcdefghijk'},
            'flexColumns': [
                {'musicResponsiveListItemFlexColumnRenderer': {'text': {'runs': [{'text': 'La Luna 🌙'}]}}},
                {'musicResponsiveListItemFlexColumnRenderer': {'text': {'runs': [{'text': 'Artist • Album • 3:05'}]}}},
            ],
        }}
        tracks = backend.music_tracks({'contents': [renderer, renderer]})
        self.assertEqual(len(tracks), 1)
        self.assertEqual(tracks[0]['title'], 'La Luna 🌙')
        self.assertEqual(tracks[0]['artist'], 'Artist')
        self.assertEqual(tracks[0]['album'], 'Album')
        self.assertEqual(tracks[0]['duration'], 185)
        self.assertEqual(tracks[0]['webpageURL'], 'https://music.youtube.com/watch?v=abcdefghijk')

    def test_arbitrary_schemes_are_rejected(self):
        for value in ['file:///etc/passwd', 'javascript:alert(1)', 'ftp://host/file', 'not a URL']:
            with self.subTest(value=value):
                with self.assertRaises(ValueError):
                    backend.media_url(value)

    def test_errors_are_valid_json(self):
        response = json.loads(backend.dispatch_json('{broken'))
        self.assertIsInstance(response['error'], str)
        response = json.loads(backend.dispatch_json('{"operation":"unknown"}'))
        self.assertIn('Unsupported', response['error'])

    def test_no_tls_verification_bypass(self):
        self.assertFalse(backend.options()['nocheckcertificate'])


if __name__ == '__main__':
    unittest.main()
