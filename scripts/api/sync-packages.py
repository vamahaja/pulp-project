import json
import logging
import argparse

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


def get_builds_from_shaman(client, sha1, branch, flavor, distro):
    # Build the URL
    url = f'{client.base_url}search/?'
    url += f'sha1={sha1}&ref={branch}&flavor={flavor}&distros={distro}'

    # Get the builds
    logger.info(f'Getting builds from Shaman: {url}')
    response = client.get(url)
    if response.status_code == 200:
        return response.json()
    elif response.status_code == 404:
        return []

    raise RuntimeError(
        'Failed to get builds from Shaman: '
        f'{response.status_code} {response.text.strip()}'
    )


def get_repository_by_name(client, repo_name):
    # Build the URL
    url = f'{client.base_url}repositories/?name={repo_name}'

    # Get the repository
    logger.info(f'Getting repository {repo_name} from Pulp')
    response = client.get(url)
    if response.status_code == 200:
        return response.json()
    elif response.status_code == 404:
        return False

    raise RuntimeError(
        'Failed to check if repository exists: '
        f'{response.status_code} {response.text.strip()}'
    )


def update_repository_remote(pulp, plugin, type, repo_name, remote_name):
    # Build the parameters
    params = { 'repository': repo_name, 'remote': remote_name }
    url = f'{pulp.base_url}repositories/{plugin}/{type}/'

    # Update the repository remote
    logger.info(f'Updating repository {repo_name} remote {remote_name} for {plugin}/{type}')
    response = pulp.post(url, json=params)
    if response.status_code != 200:
        raise RuntimeError(
            'Failed to update repository remote: '
            f'{response.status_code} {response.text.strip()}'
        )

    return response.json()


def create_remote(pulp, plugin, type, remote_name, chacra_url, distribution):
    # Build the parameters
    params = {
        'name': remote_name,
        'url': chacra_url,
        'policy': 'immediate',
        'download_concurrency': 4,
    }
    if plugin == 'deb':
        params['distributions'] = distribution

    # Build the URL
    url = f'{pulp.base_url}remotes/{plugin}/{type}/'

    # Create the remote
    logger.info(f'Creating remote {remote_name} for {plugin}/{type} from {chacra_url}')
    response = pulp.post(url, json=params)
    if response.status_code != 201:
        raise RuntimeError(
            'Failed to create remote: '
            f'{response.status_code} {response.text.strip()}'
        )

    return response.json()


def sync_build_to_pulp(shaman, pulp, distro, sha1, archs, branch, flavor):
    logger.info(f'Syncing build {sha1} to Pulp for distro {distro}')

    # Parse the distro
    distro_name, distro_version, = distro.split('-')
    _plugin, _type = 'rpm', 'rpm'
    if distro_name == 'ubuntu':
        distro_version = ubuntu_codenames.get(distro_version)
        _plugin, _type = 'deb', 'apt'

    # Parse the architectures
    for arch in archs.split(',') if archs else shaman_supported_archs:
        _distro = f'{distro_name}/{distro_version}/{arch}'
        builds = get_builds_from_shaman(shaman, sha1, branch, flavor, _distro)
        if not builds:
            logger.error(f'No builds found for distro {_distro} and architecture {arch}')
            continue

        # Check if the repository exists
        repo_name = f'{project}-{branch}-{distro_name}-{distro_version}-{arch}'
        repo = get_repository_by_name(pulp, repo_name)
        if not repo:
            logger.error(f'Repository {repo_name} not found')
            continue

        # Create the remote
        chacra_url = builds[0]['chacra_url']
        remote_name = f"chacra-{repo_name}-{sha1[:8]}"
        create_remote(pulp, _plugin, _type, remote_name, chacra_url, distro_version)

        # Update the repository remote
        update_repository_remote(pulp, _plugin, _type, repo_name, remote_name)


def main():
    # Parse arguments
    args = parse_arguments()

    # Create Shaman and Pulp client
    shaman_client = create_shaman_client()
    pulp_user_client = create_pulp_user_client()

    # Parse platforms and architectures
    distros = args.platforms.split(',') if args.platforms else supported_distros
    for distro in distros:
        sync_build_to_pulp(
            shaman_client, pulp_user_client,
            distro, args.sha1, args.archs, args.branch, args.flavor,
        )


if __name__ == '__main__':
    main()
