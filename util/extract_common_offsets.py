#!/usr/bin/env python3
import argparse
from pathlib import Path


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("input_dir", type=Path)
    parser.add_argument("output_file", type=Path)
    parser.add_argument("--first-run", type=int, default=1)
    parser.add_argument("--last-run", type=int, required=True)
    args = parser.parse_args()

    sets = []
    for run in range(args.first_run, args.last_run + 1):
        path = args.input_dir / f"CONF_SET_28_run{run}.txt"
        if not path.is_file():
            raise FileNotFoundError(path)
        sets.append(
            {
                int(line)
                for line in path.read_text().splitlines()
                if line.strip().isdigit()
            }
        )

    common = set.intersection(*sets)
    args.output_file.parent.mkdir(parents=True, exist_ok=True)
    args.output_file.write_text(
        "\n".join(str(value) for value in sorted(common)) + "\n"
    )
    print(f"common offsets: {len(common)}")
    print(f"output: {args.output_file}")


if __name__ == "__main__":
    main()
