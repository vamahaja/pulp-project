import configparser
import logging
import os
import requests

requests.packages.urllib3.disable_warnings()

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)


def read_config(config_file=os.path.expanduser('~/.config/pulp-project.ini')):
    """Load ConfigParser from default or custom path."""
    config = configparser.ConfigParser()
    config.read(config_file)

    return config


def get_config_value(config, section, key, mandatory=True):
    """Return a config key value; raise if mandatory and missing or empty."""
    value = config.get(section, key, fallback='')

    if mandatory and not value:
        raise ValueError(
            f'Config value {key} is mandatory for section {section}'
        )

    return value


def parse_tls_verify(raw):
    """Convert an INI tls_verify value to bool or a CA bundle path string."""
    if raw is None or str(raw).strip() == '':
        return True

    s = str(raw).strip()
    lower = s.lower()
    if lower in ('true', 'yes', '1', 'on'):
        return True

    if lower in ('false', 'no', '0', 'off'):
        return False

    return s


def get_shaman_config():
    """Read config.ini and return the Shaman API endpoint URL."""
    config = read_config()
    return get_config_value(config, 'shaman', 'endpoint')


def get_pulp_config():
    """Read config.ini and return Pulp URL, creds, and verify settings."""
    config = read_config()
    endpoint = get_config_value(config, 'pulp', 'endpoint')
    admin_uname = get_config_value(
        config, 'pulp', 'admin_username', mandatory=False
    )
    admin_pass = get_config_value(
        config, 'pulp', 'admin_password', mandatory=False
    )
    pulp_uname = get_config_value(config, 'pulp', 'pulp_username')
    pulp_pass = get_config_value(config, 'pulp', 'pulp_password')
    verify = parse_tls_verify(
        config.get('pulp', 'tls_verify', fallback='')
    )

    return endpoint, admin_uname, admin_pass, pulp_uname, pulp_pass, verify


def check_server_reachability(client, endpoint):
    """GET the URL and raise if the server cannot be reached."""
    logger.info(f'Checking server reachability: {endpoint}')
    try:
        client.get(endpoint, timeout=30)
        logger.info(f'Server is reachable: {endpoint}')
    except (requests.exceptions.RequestException, OSError) as e:
        detail = (
            e.response.text
            if getattr(e, 'response', None) is not None
            else str(e)
        )
        logger.error(f'Server is not reachable: {endpoint}, error: {detail}')
        raise Exception(f'Server is not reachable: {detail}') from e


def create_shaman_client():
    """Return a requests Session configured for the Shaman JSON API."""
    endpoint = get_shaman_config()
    shaman_client = requests.Session()
    shaman_client.base_url = endpoint
    shaman_client.headers.update({
        'Accept': 'application/json',
        'Content-Type': 'application/json',
    })

    check_server_reachability(shaman_client, f'{endpoint.rstrip("/")}/')

    return shaman_client


def create_pulp_user_client():
    """Return a requests Session authenticated to the Pulp API."""
    endpoint, _, _, pulp_username, pulp_password, verify = get_pulp_config()
    pulp_client = requests.Session()
    pulp_client.base_url = endpoint
    pulp_client.headers.update({
        'Accept': 'application/json',
        'Content-Type': 'application/json',
    })
    pulp_client.auth = (pulp_username, pulp_password)
    pulp_client.verify = verify

    check_server_reachability(pulp_client, f'{endpoint.rstrip("/")}/status/')

    return pulp_client
