import configparser
import requests
import logging

requests.packages.urllib3.disable_warnings()

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)


def read_config(config_file='config.ini'):
    # Read config file
    config = configparser.ConfigParser()
    config.read(config_file)

    return config


def get_config_value(config, section, key, mandatory=True):
    # Get config value from config file
    value = config.get(section, key, fallback='')

    # If config value is mandatory and not set, raise an error
    if mandatory and not value:
        raise ValueError(
            f'Config value {key} is mandatory for section {section}'
        )

    return value


def parse_tls_verify(raw):
    # INI values are strings; requests needs bool or a path to a CA bundle.
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
    # Get Shaman config from config file
    config = read_config()
    return get_config_value(config, 'shaman', 'endpoint')


def get_pulp_config():
    # Get Pulp config from config file
    config = read_config()

    # Get Pulp config values
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
    # Check if server is reachable
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
    # Create Shaman client
    endpoint = get_shaman_config()
    shaman_client = requests.Session()
    shaman_client.base_url = endpoint
    shaman_client.headers.update({
        'Accept': 'application/json',
        'Content-Type': 'application/json',
    })

    # Check if Shaman server is reachable
    check_server_reachability(shaman_client, f'{endpoint.rstrip("/")}/')

    return shaman_client


def create_pulp_user_client():
    # Create Pulp client
    endpoint, _, _, pulp_username, pulp_password, verify = get_pulp_config()

    # Create Pulp client
    pulp_client = requests.Session()
    pulp_client.base_url = endpoint
    pulp_client.headers.update({
        'Accept': 'application/json',
        'Content-Type': 'application/json',
    })
    pulp_client.auth = (pulp_username, pulp_password)
    pulp_client.verify = verify

    # Check if Pulp server is reachable
    check_server_reachability(pulp_client, f'{endpoint.rstrip("/")}/status/')

    return pulp_client
