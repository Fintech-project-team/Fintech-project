"""Produce selected scenario SQL without connecting to or changing a database."""
import argparse
from pathlib import Path
from export_state import export

if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory',type=Path)
    parser.add_argument('--cases',nargs='+',required=True)
    parser.add_argument('--out',type=Path,required=True)
    args=parser.parse_args()
    body=export(args.directory,args.cases)
    with args.out.open('x',encoding='utf-8',newline='\n') as stream:
        stream.write(body)
