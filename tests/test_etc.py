import urllib
from urllib.request import urlopen


def test_grafana():
    """그라파나 접속 테스트."""
    url = 'http://localhost:3000'
    urlopen(url)


def test_uikafka():
    """UI for Kafka 접속 테스트."""
    url = 'http://localhost:8989'
    urlopen(url)


def test_prometheus():
    """프로메테우스 접속 테스트."""
    url = 'http://localhost:9090'
    urlopen(url)


def test_k8sdashboard():
    """쿠버네티스 대쉬보드 접속 테스트."""
    url = 'https://localhost:8443'
    try:
        urlopen(url)
    except urllib.error.URLError as e:
        assert 'CERTIFICATE_VERIFY_FAILED' in str(e)