"""Copy trusted SDK templates into the installed Shell; --check guards drift."""
import pathlib
import sys
root=pathlib.Path(__file__).resolve().parents[1]
source=root/'crates/ditto-generation/templates'
destination=root/'shell/generated/templates'
checking='--check' in sys.argv
for path in sorted(source.glob('*.qml')):
    target=destination/path.name
    if checking:
        if not target.exists() or target.read_bytes()!=path.read_bytes():
            raise SystemExit('stale generated template: '+str(target))
    else:
        destination.mkdir(parents=True,exist_ok=True)
        target.write_bytes(path.read_bytes())
