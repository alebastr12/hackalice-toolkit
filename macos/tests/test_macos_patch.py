import hashlib
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('macos_patch', ROOT / 'scripts/macos_patch.py')
macos_patch = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(macos_patch)

PATCH = """--- a/hello.txt
+++ b/hello.txt
@@ -1 +1 @@
-old
+new
--- /dev/null
+++ b/added.txt
@@ -0,0 +1 @@
+fresh
"""


def digest(data):
    return hashlib.sha256(data).hexdigest()


class PatchTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        (self.root / 'hello.txt').write_bytes(b'old\n')
        (self.root / 'keep.txt').write_bytes(b'keep\n')
        manifest = {'schema': 1, 'package': 'alisa-voice', 'version': '0.3.11',
                    'platform': 'linux-x86_64',
                    'files': {'hello.txt': digest(b'old\n'), 'keep.txt': digest(b'keep\n')}}
        (self.root / macos_patch.MANIFEST).write_text(json.dumps(manifest))
        self.patch = self.root.parent / (self.root.name + '.patch')
        self.patch.write_text(PATCH)

    def tearDown(self):
        self.patch.unlink(missing_ok=True)
        self.tmp.cleanup()

    def test_apply_rewrites_manifest_and_verifies(self):
        manifest = macos_patch.apply(self.root, self.patch)
        self.assertEqual((self.root / 'hello.txt').read_text(), 'new\n')
        self.assertEqual((self.root / 'added.txt').read_text(), 'fresh\n')
        self.assertEqual(manifest['version'], '0.3.11')
        self.assertEqual(set(manifest['files']), {'hello.txt', 'keep.txt', 'added.txt'})
        self.assertEqual(macos_patch.verify(self.root)['files']['hello.txt'], digest(b'new\n'))

    def test_verify_rejects_edited_file(self):
        macos_patch.apply(self.root, self.patch)
        (self.root / 'keep.txt').write_bytes(b'tampered\n')
        with self.assertRaises(RuntimeError):
            macos_patch.verify(self.root)

    def test_missing_patch_file_is_reported(self):
        with self.assertRaises(RuntimeError):
            macos_patch.apply(self.root, self.root / 'absent.patch')


if __name__ == '__main__':
    unittest.main()
