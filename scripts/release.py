#!/usr/bin/env python3
"""Test, package, and publish the committed application version using GitHub CLI."""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]


def run(*args):
    return subprocess.check_output(args, cwd=ROOT, text=True).strip()


def execute(*args):
    subprocess.run(args, cwd=ROOT, check=True)


def require(condition, message):
    if not condition:
        raise ValueError(message)


def github_repo(url):
    match = re.fullmatch(r"(?:git@github\.com:|https://github\.com/|ssh://git@github\.com/)([\w.-]+/[\w.-]+?)(?:\.git)?/?", url)
    require(match is not None, "origin must be a GitHub.com SSH or HTTPS repository URL")
    return match.group(1)


def remote_tag_commit(output, tag):
    refs = dict(line.split()[::-1] for line in output.splitlines() if line.strip())
    return refs.get(f"refs/tags/{tag}^{{}}", refs.get(f"refs/tags/{tag}"))


def validate_assets(directory, version, commit):
    names = [f"macos-meeting-recorder-{version}-macos-arm64.dmg", "SHA256SUMS",
             "INSTALL.md", "BUILD-INFO.txt", "RELEASE-NOTES.md"]
    paths = [directory / name for name in names]
    require(all(p.is_file() and p.stat().st_size for p in paths), "Incomplete package; remove the incomplete local release directory and package again")
    metadata = dict(line.split(": ", 1) for line in paths[3].read_text().splitlines() if ": " in line)
    require(metadata.get("Commit") == commit and metadata.get("Version") == version,
            "Existing package belongs to another commit/version; do not reuse it")
    digest = hashlib.sha256(paths[0].read_bytes()).hexdigest()
    require(paths[1].read_text().strip() == f"{digest}  {names[0]}", "DMG checksum mismatch")
    return paths


def upload_missing(repo, tag, paths, remote_assets):
    existing = {asset['name']: asset for asset in remote_assets}
    for path in paths:
        digest = 'sha256:' + hashlib.sha256(path.read_bytes()).hexdigest()
        asset = existing.get(path.name)
        if asset is not None:
            require(asset.get('state') == 'uploaded' and asset.get('digest') == digest,
                    f"Remote draft asset differs or is incomplete: {path.name}; inspect it manually before retrying")
        else:
            execute('gh', 'release', 'upload', tag, str(path), '--repo', repo)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true', help='Read-only preflight; no tests, build, tags, pushes or uploads')
    parser.add_argument('--draft', action='store_true', help='Upload and verify assets, but leave the release as a draft')
    parser.add_argument('--prerelease', action='store_true', help='Publish as a prerelease instead of latest')
    args = parser.parse_args()
    require(run('uname', '-m') == 'arm64', 'An Apple Silicon Mac is required')
    version = plistlib.loads((ROOT / 'Info.plist').read_bytes())['CFBundleShortVersionString']
    require(re.fullmatch(r'\d+\.\d+\.\d+', version), 'Use a numeric x.y.z version in Info.plist')
    tag = 'v' + version
    notes = ROOT / 'docs/releases' / (tag + '.md')
    require(notes.is_file() and notes.read_text().strip(), f'Missing release notes: {notes}')
    require(not run('git', 'status', '--porcelain'), 'Commit all source/version/release-note changes first')
    repo = github_repo(run('git', 'remote', 'get-url', 'origin'))
    require(github_repo(run('git', 'remote', 'get-url', '--push', 'origin')) == repo,
            'origin fetch and push URLs point to different repositories')
    execute('gh', 'auth', 'status', '--hostname', 'github.com')
    info = json.loads(run('gh', 'repo', 'view', repo, '--json', 'nameWithOwner,defaultBranchRef,viewerPermission'))
    require(info['viewerPermission'] in ('ADMIN', 'MAINTAIN', 'WRITE'), 'GitHub account lacks repository write access')
    branch = info['defaultBranchRef']['name']
    require(run('git', 'branch', '--show-current') == branch, f'Release from the default branch: {branch}')
    commit = run('git', 'rev-parse', 'HEAD')
    # A successful list distinguishes "no release" from auth/network failures.
    releases = json.loads(run('gh', 'api', f'repos/{repo}/releases', '--paginate', '--slurp'))
    release = next((r for page in releases for r in page if r['tag_name'] == tag), None)
    require(release is None or release['draft'], f'{tag} is already published; bump the version, never overwrite a public release')
    remote = run('git', 'ls-remote', 'origin', f'refs/tags/{tag}', f'refs/tags/{tag}^{{}}')
    remote_commit = remote_tag_commit(remote, tag)
    require(remote_commit in (None, commit), f'Remote {tag} points to another commit')
    local_tags = run('git', 'tag', '--list', tag)
    if local_tags:
        require(run('git', 'rev-parse', tag + '^{}') == commit, f'Local {tag} points to another commit')
    require(release is None or remote_commit == commit, 'Existing draft has no matching remote tag')
    print(f'Ready: {repo} / {tag} / {commit}', flush=True)
    if args.check:
        return
    # No remote changes until tests and packaging finish successfully.
    execute(sys.executable, '-m', 'unittest', 'discover', '-s', 'tests', '-p', 'test_*.py')
    for test in ('lifecycle', 'software-aec', 'speakers', 'playback'):
        execute('bash', f'scripts/test-{test}.sh')
    directory = ROOT / 'build/releases' / tag
    if not directory.exists():
        execute('bash', 'scripts/package-dmg.sh')
    paths = validate_assets(directory, version, commit)
    require(paths[4].read_bytes() == notes.read_bytes(), 'Packaged release notes differ from committed notes')
    execute('hdiutil', 'verify', str(paths[0]))
    require(not run('git', 'status', '--porcelain') and run('git', 'rev-parse', 'HEAD') == commit,
            'Source changed during testing/build; aborting')
    # Fetch updates only after --check, and refuse divergence instead of force-pushing.
    execute('git', 'fetch', 'origin', branch)
    execute('git', 'merge-base', '--is-ancestor', 'FETCH_HEAD', commit)
    if not local_tags:
        execute('git', 'tag', '-a', tag, '-m', f'macOS Meeting Recorder {tag}', commit)
    execute('git', 'push', '--atomic', 'origin', f'HEAD:refs/heads/{branch}', f'refs/tags/{tag}')
    if release is None:
        execute('gh', 'release', 'create', tag, '--repo', repo, '--verify-tag', '--draft',
                '--title', f'{tag} · macOS 会议录音', '--notes-file', str(notes))
    else:
        execute('gh', 'release', 'edit', tag, '--repo', repo, '--draft',
                '--title', f'{tag} · macOS 会议录音', '--notes-file', str(notes))
    release = json.loads(run('gh', 'api', f'repos/{repo}/releases/tags/{tag}'))
    require(release['draft'], 'Release was published concurrently; refusing to change assets')
    upload_missing(repo, tag, paths, release['assets'])
    verified = json.loads(run('gh', 'api', f'repos/{repo}/releases/tags/{tag}'))
    require(verified['draft'], 'Release was published concurrently; inspect it manually')
    remote_assets = {a['name']: a for a in verified['assets']}
    for path in paths:
        asset = remote_assets.get(path.name, {})
        require(asset.get('state') == 'uploaded' and
                asset.get('digest') == 'sha256:' + hashlib.sha256(path.read_bytes()).hexdigest(),
                f'Uploaded asset verification failed: {path.name}')
    execute('gh', 'release', 'edit', tag, '--repo', repo,
            '--prerelease=' + str(args.prerelease).lower(),
            '--draft=' + str(args.draft).lower(),
            '--latest=' + str(not args.prerelease and not args.draft).lower())
    print(run('gh', 'release', 'view', tag, '--repo', repo, '--json', 'url', '--jq', '.url'))


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, KeyError, subprocess.CalledProcessError) as error:
        print(f'Release stopped: {error}', file=sys.stderr)
        sys.exit(1)
