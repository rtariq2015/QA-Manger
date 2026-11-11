"""Copy the self-contained design preview; build-time only, no runtime dependencies."""
import argparse
from pathlib import Path
parser=argparse.ArgumentParser();parser.add_argument('--output',default='/workspace/CT_QA_Manager_Design_Options.html');args=parser.parse_args()
source=Path(__file__).with_name('DesignOptions.html')
Path(args.output).write_bytes(source.read_bytes())
print(args.output)
