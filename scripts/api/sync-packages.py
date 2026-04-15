import argparse
import logging

from operations import (
    create_distribution,
    create_publication,
    create_remote,
    get_builds_from_shaman,
    get_repository_by_name,
    sync_repository,
    update_repository_remote,
)
from utils import create_shaman_client, create_pulp_user_client


logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

project = 'ceph'
ubuntu_codenames = { '22.04': 'jammy', '24.04': 'noble' }
supported_distros = [
    'rocky-10', 'centos-9', 'ubuntu-22.04', 'ubuntu-24.04', 'windows-1809'
]
shaman_supported_archs = ['x86_64', 'arm64']
distro_supported_archs = {
    'rocky': ['noarch', 'x86_64', 'aarch64', 'SRPMS'],
    'centos': ['noarch', 'x86_64', 'aarch64', 'SRPMS'],
    'ubuntu': ['x86_64', 'arm64'],
    'windows': ['x86_64', 'arm64'],
}


def parse_arguments():
    """Build argparse definitions and return parsed CLI arguments."""
    parser = argparse.ArgumentParser(
        description='Sync packages from Shaman to Pulp'
    )
    parser.add_argument(
        '--sha1', type=str, required=True, help='SHA1 commit hash'
    )
    parser.add_argument(
        '--flavor', type=str, required=True, help='Flavor of the build'
    )

    parser.add_argument(
        '--branch', type=str, required=False, help='Ceph branch'
    )
    parser.add_argument(
        '--platforms',
        type=str,
        required=False,
        help='Comma-separated distros and distro versions'
    )
    parser.add_argument(
        '--archs',
        type=str,
        required=False,
        help='Comma-separated architectures per distro and distro version'
    )

    return parser.parse_args()


def sync_chacra_arch_into_pulp(
    pulp,
    plugin,
    type,
    branch,
    sha1,
    flavor,
    distro_name,
    distro_version,
    distro_arch,
    build_base_url,
    version,
):
    """Sync repo arch from Shaman into Pulp."""
    short_sha1 = sha1[-8:]
    repo_name = (
        f'{project}-{branch}-{distro_name}-{distro_version}-{distro_arch}'
    )
    chacra_url = (
        f'{build_base_url}'
        if distro_name == 'ubuntu'
        else f'{build_base_url}{distro_arch}'
    )
    logger.info(
        f'Pulp publish pipeline: repo={repo_name} plugin={plugin}/{type} '
        f'flavor={flavor} branch={branch} sha1={short_sha1}… '
        f'upstream={chacra_url}'
    )
    repo_href = get_repository_by_name(pulp, repo_name)
    if not repo_href:
        logger.error(f'Repository {repo_name} not found')
        return

    remote_name = f'chacra-{repo_name}-{short_sha1}'
    remote = create_remote(
        pulp,
        plugin,
        type,
        remote_name,
        chacra_url,
        distro_version,
    )
    remote_href = remote['pulp_href']

    update_repository_remote(pulp, repo_href, remote_href)
    sync_repository(pulp, repo_href)

    publication = create_publication(pulp, plugin, type, repo_href)
    publication_href = publication['pulp_href']
    distribution_name = f'dist-{repo_name}-{short_sha1}'
    base_path = (
        f'repos/{project}/{branch}/{sha1}/{distro_name}/{distro_version}'
        f'/flavors/{flavor}/{distro_arch}'
    )
    labels = {
        'ref': branch,
        'arch': distro_arch,
        'sha1': sha1,
        'distro': distro_name,
        'distro_version': distro_version,
        'flavors': flavor,
        'project': project,
        'version': version,
    }
    create_distribution(
        pulp, plugin, type, distribution_name, base_path, publication_href, labels
    )
    logger.info(
        f'Pulp publish pipeline finished: repo={repo_name} '
        f'distribution={distribution_name} base_path={base_path}'
    )


def sync_build_to_pulp(shaman, pulp, distro, sha1, archs, branch, flavor):
    """Sync distro from Shaman through Pulp for all repo archs."""
    logger.info(f'Syncing build {sha1} to Pulp for distro {distro}')

    distro_name, distro_version, = distro.split('-')
    _plugin, _type = 'rpm', 'rpm'
    if distro_name == 'ubuntu':
        distro_version = ubuntu_codenames.get(distro_version)
        _plugin, _type = 'deb', 'apt'

    for arch in archs.split(',') if archs else shaman_supported_archs:
        if distro_name in ['centos', 'rocky'] and arch == 'arm64':
            logger.info(
                f'Skipping arm64 for {distro_name} {distro_version} '
                f'{arch} because it is already synced'
            )
            continue

        _distro = f'{distro_name}/{distro_version}/{arch}'
        builds = get_builds_from_shaman(shaman, sha1, branch, flavor, _distro)
        if not builds:
            logger.error(
                f'No builds found for distro {_distro} '
                f'and architecture {arch}'
            )
            continue
        build_base_url = builds[0]['url']
        version = builds[0]['extra']['version']
        logger.info(
            f'Shaman build found for {_distro} (Shaman search arch={arch}): '
            f'base URL {build_base_url} version {version}'
        )

        for distro_arch in distro_supported_archs.get(distro_name, []):
            sync_chacra_arch_into_pulp(
                pulp,
                _plugin,
                _type,
                branch,
                sha1,
                flavor,
                distro_name,
                distro_version,
                distro_arch,
                build_base_url,
                version,
            )


def main():
    """Main entry point."""
    args = parse_arguments()
    shaman_client = create_shaman_client()
    pulp_user_client = create_pulp_user_client()
    distros = (
        args.platforms.split(',')
        if args.platforms
        else supported_distros
    )
    arch_filter = args.archs or '(default shaman archs)'
    logger.info(
        f'Starting sync: {len(distros)} platform(s), sha1={args.sha1}, '
        f'flavor={args.flavor}, branch={args.branch}, '
        f'arch filter={arch_filter}'
    )
    for distro in distros:
        sync_build_to_pulp(
            shaman_client, pulp_user_client,
            distro, args.sha1, args.archs, args.branch, args.flavor,
        )


if __name__ == '__main__':
    main()
