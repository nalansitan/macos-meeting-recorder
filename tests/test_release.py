import hashlib
import importlib.util
import json
from pathlib import Path
import plistlib
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location('release', Path(__file__).parents[1] / 'scripts/release.py')
release = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(release)


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.commit = 'a' * 40
        (self.root / 'Info.plist').write_bytes(plistlib.dumps({'CFBundleShortVersionString': '1.2.3'}))
        notes = self.root / 'docs/releases/v1.2.3.md'
        notes.parent.mkdir(parents=True)
        notes.write_text('Release notes')
        self.out = self.root / 'build/releases/v1.2.3'
        self.out.mkdir(parents=True)
        dmg = self.out / 'macos-meeting-recorder-1.2.3-macos-arm64.dmg'
        dmg.write_bytes(b'test dmg')
        (self.out / 'SHA256SUMS').write_text(hashlib.sha256(dmg.read_bytes()).hexdigest() + '  ' + dmg.name + '\n')
        (self.out / 'BUILD-INFO.txt').write_text(f'Version: 1.2.3\nCommit: {self.commit}\n')
        (self.out / 'INSTALL.md').write_text('Install')
        (self.out / 'RELEASE-NOTES.md').write_text('Release notes')
        self.calls = []
        self.remote = None
        self.tag = ''
        self.dirty = False
        self.fail_upload = False

    def fake_run(self, *args):
        if args == ('uname', '-m'): return 'arm64'
        if args == ('git', 'status', '--porcelain'): return ' M dirty' if self.dirty else ''
        if args[:3] == ('git', 'remote', 'get-url'): return 'git@github.com:owner/project.git'
        if args[:3] == ('gh', 'repo', 'view'):
            return json.dumps({'defaultBranchRef': {'name': 'main'}, 'viewerPermission': 'ADMIN'})
        if args == ('git', 'branch', '--show-current'): return 'main'
        if args[:2] == ('git', 'rev-parse'): return self.commit
        if args[:2] == ('git', 'ls-remote'):
            return f'{self.commit}\trefs/tags/v1.2.3' if self.tag else ''
        if args[:3] == ('git', 'tag', '--list'): return self.tag
        if args[:2] == ('gh', 'api'):
            if args[2].endswith('/releases'): return json.dumps([[self.remote] if self.remote else []])
            return json.dumps(self.remote)
        if args[:3] == ('gh', 'release', 'view'): return 'https://github.com/owner/project/releases/tag/v1.2.3'
        raise AssertionError(args)

    def fake_execute(self, *args):
        self.calls.append(args)
        if args[:3] == ('gh', 'release', 'create'):
            self.remote = {'tag_name': 'v1.2.3', 'draft': True, 'assets': []}
        if args[:3] == ('gh', 'release', 'upload'):
            if self.fail_upload and len(self.remote['assets']) == 2:
                raise OSError('connection lost')
            path = Path(args[4])
            self.remote['assets'].append({'name': path.name, 'state': 'uploaded',
                                         'digest': 'sha256:' + hashlib.sha256(path.read_bytes()).hexdigest()})
        if args[:2] == ('git', 'tag'): self.tag = 'v1.2.3'

    def invoke(self, *args):
        with patch.object(release, 'ROOT', self.root), patch.object(release, 'run', self.fake_run), \
             patch.object(release, 'execute', self.fake_execute), patch('sys.argv', ['release.py', *args]):
            release.main()

    def published(self):
        return any(c[:3] == ('gh', 'release', 'edit') and '--draft=false' in c for c in self.calls)

    def test_end_to_end_publishes_only_after_all_uploads(self):
        self.invoke()
        self.assertEqual(len(self.remote['assets']), 5)
        self.assertTrue(self.published())
        upload_indices = [i for i, c in enumerate(self.calls) if c[:3] == ('gh', 'release', 'upload')]
        publish_index = next(i for i, c in enumerate(self.calls) if '--draft=false' in c)
        self.assertLess(max(upload_indices), publish_index)

    def test_upload_failure_retains_draft_and_retry_resumes(self):
        self.fail_upload = True
        with self.assertRaises(OSError): self.invoke()
        self.assertFalse(self.published())
        self.assertTrue(self.remote['draft'])
        self.assertEqual(len(self.remote['assets']), 2)
        self.fail_upload = False
        self.invoke()
        self.assertTrue(self.published())
        self.assertEqual(sum(c[:3] == ('gh', 'release', 'create') for c in self.calls), 1)
        self.assertEqual(len(self.remote['assets']), 5)

    def test_draft_mode_does_not_publish(self):
        self.invoke('--draft')
        self.assertFalse(self.published())
        self.assertEqual(len(self.remote['assets']), 5)

    def test_existing_public_release_is_never_modified(self):
        self.remote = {'tag_name': 'v1.2.3', 'draft': False, 'assets': []}
        with self.assertRaisesRegex(ValueError, 'already published'): self.invoke()
        self.assertFalse(any(c[0] == 'git' or c[:2] == ('gh', 'release') for c in self.calls))

    def test_read_only_check(self):
        self.invoke('--check')
        self.assertEqual(self.calls, [('gh', 'auth', 'status', '--hostname', 'github.com')])

    def test_dirty_worktree_stops_before_remote_changes(self):
        self.dirty = True
        with self.assertRaisesRegex(ValueError, 'Commit all'): self.invoke()
        self.assertEqual(self.calls, [])

    def test_stale_package_stops_before_tag_or_push(self):
        (self.out / 'BUILD-INFO.txt').write_text('Version: 1.2.3\nCommit: other\n')
        with self.assertRaisesRegex(ValueError, 'another commit'): self.invoke()
        self.assertFalse(any(c[:2] in [('git', 'tag'), ('git', 'push')] for c in self.calls))

    def test_checksum_corruption_stops(self):
        (self.out / 'macos-meeting-recorder-1.2.3-macos-arm64.dmg').write_bytes(b'corrupt')
        with self.assertRaisesRegex(ValueError, 'checksum'): self.invoke()
        self.assertFalse(self.published())

    def test_existing_draft_asset_mismatch_is_not_clobbered(self):
        self.tag = 'v1.2.3'
        self.remote = {'tag_name': self.tag, 'draft': True, 'assets': [
            {'name': 'macos-meeting-recorder-1.2.3-macos-arm64.dmg', 'state': 'uploaded', 'digest': 'sha256:other'}]}
        with self.assertRaisesRegex(ValueError, 'differs'): self.invoke()
        self.assertFalse(any('--clobber' in c for c in self.calls))
        self.assertFalse(self.published())

    def test_repo_url_parsing_and_annotated_tags(self):
        for url in ['git@github.com:owner/project.git', 'https://github.com/owner/project',
                    'ssh://git@github.com/owner/project.git']:
            self.assertEqual(release.github_repo(url), 'owner/project')
        with self.assertRaises(ValueError): release.github_repo('https://example.com/owner/project')
        self.assertEqual(release.remote_tag_commit('tagsha refs/tags/v1.2.3\ncommit refs/tags/v1.2.3^{}', 'v1.2.3'), 'commit')
