#!/usr/bin/env python3
"""Apply the macOS host patch to an unpacked Alisa Voice release.

The upstream installer validates `package-manifest.json` before doing anything.
A patch changes file contents (and may add files), so the manifest has to be
recomputed before the stock `scripts/release.py --install` runs.
"""
import argparse
import hashlib
import json
import subprocess
from pathlib import Path

MANIFEST = 'package-manifest.json'


def sha256(path):
    digest = hashlib.sha256()
    with Path(path).open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(chunk)
    return digest.hexdigest()


def actual_files(root):
    root = Path(root)
    return {path.relative_to(root).as_posix() for path in root.rglob('*')
            if path.is_file() and path.name != MANIFEST
            and '__pycache__' not in path.parts and path.suffix != '.pyc'
            and path.name != '.DS_Store'}


def load(root):
    value = json.loads((Path(root) / MANIFEST).read_text(encoding='utf-8'))
    if (not isinstance(value, dict) or value.get('package') != 'alisa-voice'
            or not isinstance(value.get('files'), dict) or not value['files']):
        raise RuntimeError('Неизвестный пакет: package-manifest.json не от Alisa Voice.')
    return value


def rewrite_manifest(root):
    """Recompute every hash, keeping the upstream version and platform."""
    root = Path(root)
    manifest = load(root)
    listed = set(manifest['files'])
    present = actual_files(root)
    missing = listed - present
    if missing:
        raise RuntimeError('После патча пропали файлы пакета: ' + ', '.join(sorted(missing)[:5]))
    manifest['files'] = {name: sha256(root / name) for name in sorted(present)}
    (root / MANIFEST).write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    return manifest


def verify(root):
    root = Path(root)
    manifest = load(root)
    if actual_files(root) != set(manifest['files']):
        raise RuntimeError('Состав пакета не совпал с manifest.')
    for name, expected in manifest['files'].items():
        if sha256(root / name) != expected:
            raise RuntimeError('Повреждён файл пакета: ' + name)
    return manifest


def apply(root, patch):
    root, patch = Path(root), Path(patch).resolve()
    if not patch.is_file():
        raise RuntimeError('Файл патча не найден: ' + str(patch))
    result = subprocess.run(['patch', '-t', '-N', '-F0', '-p1', '-d', str(root), '-i', str(patch)],
                            capture_output=True)
    if result.returncode:
        detail = (result.stdout + result.stderr).decode(errors='replace').strip().splitlines()
        raise RuntimeError('macOS-патч не применился к этой версии релиза: ' + ' '.join(detail[:6]))
    manifest = rewrite_manifest(root)
    for path in root.rglob('*.py'):
        if '__pycache__' not in path.parts:
            try:
                compile(path.read_bytes(), str(path), 'exec')
            except SyntaxError as error:
                raise RuntimeError('Патч оставил синтаксическую ошибку в ' + str(path.relative_to(root)) + ': ' + str(error)) from None
    return manifest


def main():
    parser = argparse.ArgumentParser(description='Применить darwin-патч к распакованному релизу.')
    parser.add_argument('--root', required=True, type=Path)
    parser.add_argument('--patch', type=Path)
    parser.add_argument('--verify-only', action='store_true')
    parser.add_argument('--expect-version')
    args = parser.parse_args()
    manifest = verify(args.root) if args.verify_only or not args.patch else apply(args.root, args.patch)
    manifest = verify(args.root) if args.patch else manifest
    if args.expect_version and manifest.get('version') != args.expect_version:
        raise RuntimeError('Ожидалась версия ' + args.expect_version + ', в архиве ' + str(manifest.get('version')))
    print('Пакет проверен: версия ' + str(manifest.get('version')) + ', файлов ' + str(len(manifest['files'])))


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, RuntimeError) as error:
        print('Остановлено: ' + str(error), file=__import__('sys').stderr)
        raise SystemExit(1)
