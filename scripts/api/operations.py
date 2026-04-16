import logging
from shlex import join
import requests
import time

from urllib.parse import urlparse


requests.packages.urllib3.disable_warnings()

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)


def get_builds_from_shaman(client, sha1, branch, flavor, distro):
    """Query Shaman for builds matching the given parameters."""
    url = f'{client.base_url}search/?'
    url += f'sha1={sha1}&ref={branch}&flavor={flavor}&distros={distro}'

    logger.info(f'Getting builds from Shaman: {url}')

    response = client.get(url)
    if response.status_code == 200:
        return response.json()

    if response.status_code == 404:
        return []

    raise RuntimeError(
        f'Failed to get builds from Shaman: '
        f'{response.status_code} {response.text.strip()}'
    )


def _pulp_api_url(client, href):
    """Convert Pulp href to an absolute URL."""
    if href.startswith('http://') or href.startswith('https://'):
        return href

    if href.startswith('/'):
        base = urlparse(client.base_url)
        return f'{base.scheme}://{base.netloc}{href}'

    return f'{client.base_url.rstrip('/')}/{href.lstrip("/")}'


def _task_href_from_response(response):
    """Return task URL from Pulp JSON body, or None if missing."""
    try:
        data = response.json()
    except ValueError:
        return None

    if isinstance(data, dict):
        return data.get('task')

    return None


def poll_pulp_task(pulp, task_href, timeout=3600, interval=10):
    """Poll Pulp task until expected state is reached."""
    task_url = _pulp_api_url(pulp, task_href)
    logger.info(
        f'Waiting for Pulp background task (timeout {timeout}s): {task_url}'
    )

    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        response = pulp.get(task_url)
        if response.status_code != 200:
            raise RuntimeError(
                f'Failed to poll Pulp task: '
                f'{response.status_code} {response.text.strip()}'
            )

        data = response.json()
        state = data.get('state')
        if state == 'completed':
            logger.info(f'Pulp task completed: {task_url}')
            return data

        if state in ('failed', 'canceled'):
            raise RuntimeError(
                f'Pulp task ended with state {state}: {response.text.strip()}'
            )

        logger.debug(f'Pulp task state={state} (still waiting): {task_url}')
        time.sleep(interval)

    raise RuntimeError(f'Pulp task timed out after {timeout}s: {task_url}')


def _finish_async_response(pulp, response, ok_codes, operation_label):
    """Get JSON for immediate responses"""
    if response.status_code in ok_codes:
        if not response.content:
            return {}

        try:
            return response.json()
        except ValueError:
            return {}

    if response.status_code == 202:
        task_href = _task_href_from_response(response)
        if not task_href:
            raise RuntimeError(
                f'{operation_label}: async response missing task href: '
                f'{response.status_code} {response.text.strip()}'
            )
        logger.info(f'{operation_label}: polling task href={task_href}')

        poll_pulp_task(pulp, task_href)
        logger.info(f'{operation_label}: task completed')
        return {}

    raise RuntimeError(
        f'{operation_label}: {response.status_code} {response.text.strip()}'
    )


def get_repository_by_name(client, repo_name):
    """Get repository by name and return pulp_href"""
    logger.info(f'Getting repository {repo_name} from Pulp')

    response = client.get(f'{client.base_url}repositories/?name={repo_name}')
    if response.status_code == 200:
        data = response.json()
        results = data.get('results') or []
        if not results:
            return None

        href = results[0].get('pulp_href')
        if not href:
            raise RuntimeError(
                f'Repository {repo_name} listing missing pulp_href: {data}'
            )
        return href

    if response.status_code == 404:
        return None

    raise RuntimeError(
        f'Failed to check if repository exists: '
        f'{response.status_code} {response.text.strip()}'
    )


def update_repository_remote(pulp, repository_href, remote_href):
    """Set a repository's default remote."""
    logger.info(
        f'Setting repository remote_href={remote_href} '
        f'for repository_href={repository_href}'
    )

    response = pulp.patch(
        _pulp_api_url(pulp, repository_href), json={'remote': remote_href}
    )

    return _finish_async_response(
        pulp, response, (200, 202), 'Failed to update repository remote'
    )


def create_remote(pulp, plugin, type, remote_name, chacra_url, distribution):
    """Create Pulp remote for chacra_url."""
    logger.info(
        f'Creating {plugin}/{type} remote name={remote_name} '
        f'url={chacra_url} distribution={distribution}'
    )

    params = {
        'name': remote_name,
        'url': chacra_url,
        'policy': 'immediate',
        'download_concurrency': 4,
    }
    if plugin == 'deb':
        params['distributions'] = distribution

    response = pulp.post(
        f'{pulp.base_url}remotes/{plugin}/{type}/', json=params
    )
    if response.status_code == 201:
        return response.json()

    raise RuntimeError(
        f'Failed to create {plugin}/{type} remote name={remote_name} '
        f'url={chacra_url} distribution={distribution}: '
        f'HTTP {response.status_code} {response.text.strip()}'
    )


def sync_repository(pulp, repository_href):
    """Start repository sync."""
    sync_url = f'{repository_href.rstrip("/")}/sync/'
    sync_url = _pulp_api_url(pulp, sync_url)

    logger.info(f'Starting repository sync: {sync_url}')

    response = pulp.post(sync_url, json={'mirror': True})
    _finish_async_response(
        pulp, response, (200, 202), 'Failed to start repository sync'
    )

    logger.info(f'Repository sync finished: {sync_url}')


def create_publication(pulp, plugin, type, repository_href):
    """Create a publication for repository_href."""
    logger.info(
        f'Creating {plugin}/{type} publication for '
        f'repository_href={repository_href}'
    )

    params = { 'repository': repository_href }
    response = pulp.post(
        f'{pulp.base_url}publications/{plugin}/{type}/', json=params
    )
    if response.status_code == 201:
        if not response.content:
            return {}

        body = response.json()
        href_or_body = body.get('pulp_href', body)
        logger.info(f'Publication created (HTTP 201): {href_or_body}')
        return body

    if response.status_code == 202:
        task_href = _task_href_from_response(response)
        if not task_href:
            raise RuntimeError(
                f'Failed to create {plugin}/{type} publication for '
                f'repository_href={repository_href}: '
                f'HTTP {response.status_code} {response.text.strip()}'
            )

        logger.info(
            f'Publication create returned HTTP 202; '
            f'polling task href={task_href}'
        )
        task = poll_pulp_task(pulp, task_href)
        created = task.get('created_resources') or []
        if not created:
            raise RuntimeError(
                f'{plugin}/{type} publication task completed but '
                f'created_resources is empty: '
                f'{task}'
            )

        pub_href = created[0]
        logger.info(f'Publication created (async): {pub_href}')

        return {'pulp_href': pub_href}

    raise RuntimeError(
        f'Failed to create publication: '
        f'{response.status_code} {response.text.strip()}'
    )


def create_distribution(
    pulp, plugin, type, distribution_name, base_path, publication_href, labels={}
):
    """Create a distribution at base_path for publication_href."""
    logger.info(
        f'Creating {plugin}/{type} distribution name={distribution_name} '
        f'base_path={base_path} publication_href={publication_href} '
        f'with labels {labels}'
    )

    params = {
        'name': distribution_name,
        'base_path': base_path,
        'publication': publication_href,
    }
    if labels:
        params['pulp_labels'] = labels

    response = pulp.post(
        f'{pulp.base_url}distributions/{plugin}/{type}/', json=params
    )
    if response.status_code == 201:
        if not response.content:
            return {}

        body = response.json()
        href_or_body = body.get('pulp_href', body)
        logger.info(
            f'{plugin}/{type} distribution created (HTTP 201): '
            f'name={distribution_name} '
            f'base_path={base_path} '
            f'publication_href={publication_href} '
            f'pulp_href={href_or_body}'
        )
        return body

    if response.status_code == 202:
        task_href = _task_href_from_response(response)
        if not task_href:
            raise RuntimeError(
                f'Failed to create distribution: '
                f'async response missing task href: '
                f'{response.status_code} {response.text.strip()}'
            )
        logger.info(
            f'{plugin}/{type} distribution create returned HTTP 202; '
            f'polling task href={task_href}'
        )

        task = poll_pulp_task(pulp, task_href)
        created = task.get('created_resources') or []
        if not created:
            raise RuntimeError(
                f'{plugin}/{type} distribution task completed but '
                f'created_resources is empty: {task}'
            )

        dist_href = created[0]
        logger.info(
            f'{plugin}/{type} distribution created (async): '
            f'name={distribution_name} '
            f'base_path={base_path} '
            f'publication_href={publication_href} '
            f'pulp_href={dist_href}'
        )

        return {'pulp_href': dist_href}

    raise RuntimeError(
        f'Failed to create distribution: '
        f'{response.status_code} {response.text.strip()}'
    )
