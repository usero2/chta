"""Check generated native bindings before a --no-pub Flutter build."""
import json
import sys
from pathlib import Path

app = Path(__file__).resolve().parents[1] / 'apps' / 'flutter_app'
metadata = json.loads((app / '.flutter-plugins-dependencies').read_text(encoding='utf-8'))
platform = sys.argv[1] if len(sys.argv) > 1 else 'android'
if platform == 'android':
    source = app / 'android/app/src/main/java/io/flutter/plugins/GeneratedPluginRegistrant.java'
elif platform == 'windows':
    source = app / 'windows/flutter/generated_plugins.cmake'
else:
    raise SystemExit('Supported platforms: android, windows')
registered = source.read_text(encoding='utf-8')
expected = [plugin['name'] for plugin in metadata['plugins'][platform] if plugin.get('native_build')]
missing = [name for name in expected if name not in registered]
if missing:
    raise SystemExit(f'Stale {platform} plugin registration: {", ".join(missing)}. Run flutter pub get successfully before building.')
print(f'{platform}: {len(expected)} native plugins registered')
