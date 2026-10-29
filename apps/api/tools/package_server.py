"""2026-10-29: 실행 JAR와 비밀 없는 설치 자료만 새 폴더에 묶는다. 사용: 배포 CLI."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
from zipfile import BadZipFile, ZipFile


API = Path(__file__).resolve().parents[1]
FILES = ('server.properties.example', 'README.md')


def check_jar(path):
    """2026-10-29: PAYSE 실행 JAR인지 확인하며 임의 ZIP은 거절한다. 사용: package."""
    with ZipFile(path) as archive:
        manifest = archive.read('META-INF/MANIFEST.MF').decode('utf-8')
        values = dict(line.split(': ', 1) for line in manifest.splitlines() if ': ' in line)
        if values.get('Start-Class') != 'com.payse.api.PayseApiApplication' \
                or values.get('Main-Class') != 'org.springframework.boot.loader.launch.JarLauncher' \
                or values.get('Build-Jdk-Spec') != '21' \
                or 'BOOT-INF/classes/com/payse/api/PayseApiApplication.class' not in archive.namelist():
            raise ValueError('A PAYSE executable JAR built with Java 21 is required')


def package(jar, output):
    """2026-10-29: 기존 폴더를 덮지 않고 지정한 네 파일만 생성한다. 사용: CLI·단위 검사."""
    jar = Path(jar).resolve(strict=True)
    output = Path(output).absolute()
    if output.exists() or output.is_symlink():
        raise ValueError('Output must be a new directory; existing contents are never replaced')
    check_jar(jar)
    sources = {name: API / 'deploy' / name for name in FILES}
    if not all(path.is_file() for path in sources.values()):
        raise ValueError('Deployment templates are missing')
    output.mkdir(parents=True, exist_ok=False)
    shutil.copyfile(jar, output / 'server.jar')
    for name, source in sources.items():
        shutil.copyfile(source, output / name)
    checksums = {name: hashlib.sha256((output / name).read_bytes()).hexdigest()
                 for name in ('server.jar', *FILES)}
    (output / 'manifest.json').write_text(json.dumps({
        'format': 'payse-server-package-v1', 'javaMajor': 21, 'sha256': checksums,
    }, indent=2) + '\n', encoding='utf-8')
    return output


def main():
    """2026-10-29: 빌드 결과와 출력 위치를 명시적으로 받는다. 사용: 직접 실행."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--jar', type=Path, help='Existing PAYSE bootJar; defaults to the single build/libs JAR')
    parser.add_argument('--output', type=Path, required=True, help='New installation bundle directory')
    args = parser.parse_args()
    jar = args.jar
    if jar is None:
        jars = list((API / 'build/libs').glob('*.jar'))
        if len(jars) != 1:
            parser.error('Build exactly one bootJar or supply --jar')
        jar = jars[0]
    try:
        package(jar, args.output)
    except (OSError, ValueError, KeyError, BadZipFile) as failure:
        parser.exit(1, f'Package creation failed ({type(failure).__name__}); no existing directory was replaced.\n')
    print('Server package created. Configure external settings and secrets before starting.')


if __name__ == '__main__':
    main()
