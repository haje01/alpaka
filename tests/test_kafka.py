from ..util import kcli


def test_topic_list():
    """기본 토픽 나열."""
    ret = kcli("kafka-topics.sh {bs} --list")
    ans = set([
        '__consumer_offsets', 
        'connect-configs', 
        'connect-offsets', 
        'connect-status']) 
    com = ans & set(ret.split('\n'))
    assert len(com) == 4
