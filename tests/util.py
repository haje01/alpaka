from subprocess import run 


def find_tool_pod():
    """현재 설치에서 Tool 파드 이름 찾기."""
    out = run(['kubectl', 'get', 'pods'], capture_output=True)
    for line in out.stdout.decode().split('\n'):
        print(line)
        if 'alpaka-tool' in line:
            pname = line.split()[0]
            return pname


def kcli(cmd):
    """알파카 Tool 컨테이너에서 kafka CLI 호출.
    
    {bs} 플레이스 홀더 위치에 --bootstrap-servers=... 자동으로 채워줌 
    
    """
    tpod = find_tool_pod()
    rel = tpod.split('-')[0]
    bs = f'--bootstrap-server={rel}-kafka-headless:9092'
    cmd = cmd.format(bs=bs).split()
    out = run(['kubectl', 'exec', tpod, '--'] + cmd, capture_output=True)
    assert out.returncode == 0
    return out.stdout.decode()

