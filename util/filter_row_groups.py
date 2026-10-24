#!/usr/bin/env python3
import argparse
from pathlib import Path


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("input_file", type=Path)
    parser.add_argument("output_file", type=Path)
    parser.add_argument("--size", type=int, default=8)
    args = parser.parse_args()

    kept = []
    discarded = []
    for line_number, line in enumerate(
        args.input_file.read_text().splitlines(), start=1
    ):
        values = [value for value in line.split() if value]
        if len(values) == args.size:
            kept.extend(values)
        elif values:
            discarded.append((line_number, len(values)))

    args.output_file.parent.mkdir(parents=True, exist_ok=True)
    args.output_file.write_text("\n".join(kept) + "\n")
    print(f"kept groups: {len(kept) // args.size}")
    print(f"kept offsets: {len(kept)}")
    print(f"discarded groups: {len(discarded)}")
    for line_number, count in discarded:
        print(f"discarded line {line_number}: {count} offsets")


if __name__ == "__main__":
    main()
