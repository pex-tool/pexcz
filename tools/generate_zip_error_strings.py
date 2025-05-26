# /// script
# requires-python = ">=3.9"
# ///

import re
import sys
from argparse import ArgumentParser
from pathlib import Path
from textwrap import dedent
from typing import Any


def main() -> Any:
    parser = ArgumentParser()
    parser.add_argument("-I", "--include-dir", type=Path, required=True)
    parser.add_argument("output_file", nargs=1, type=Path)
    options = parser.parse_args()

    include_dir: Path = options.include_dir
    with options.output_file[0].open("w") as fp:
        fp.write(
            dedent(
                """\
                #include "zipint.h"

                #define L ZIP_ET_LIBZIP
                #define N ZIP_ET_NONE
                #define S ZIP_ET_SYS
                #define Z ZIP_ET_ZLIB

                #define E ZIP_DETAIL_ET_ENTRY
                #define G ZIP_DETAIL_ET_GLOBAL

                const struct _zip_err_info _zip_err_str[] = {
                """
            )
        )

        # From cmake/GenerateZipErrorStrings.cmake:
        #
        # foreach(errln ${zip_h_err})
        #   string(REGEX MATCH "#define ZIP_ER_([A-Z0-9_]+) ([0-9]+)[ \t]+/([-*0-9a-zA-Z, ']*)/" err_t_tt ${errln})
        #   string(REGEX MATCH "([L|N|S|Z]+) ([-0-9a-zA-Z,, ']*)" err_t_tt "${CMAKE_MATCH_3}")
        #   string(STRIP "${CMAKE_MATCH_2}" err_t_tt)
        #   string(APPEND zip_err_str "    { ${CMAKE_MATCH_1}, \"${err_t_tt}\" },\n")
        # endforeach()
        for line in (include_dir / "zip.h").read_text().splitlines():
            match = re.match(
                r"#define ZIP_ER_([A-Z0-9_]+) ([0-9]+)[ \t]+/([-*0-9a-zA-Z, ']*)/", line
            )
            if not match:
                continue
            match = re.search(r"([LNSZ]+) ([-0-9a-zA-Z, ']*)", match.group(3))
            if not match:
                continue
            CMAKE_MATCH_1 = match.group(1)
            err_t_tt = match.group(2).strip()
            fp.write(f'    {{ {CMAKE_MATCH_1}, "{err_t_tt}" }},\n')

        fp.write(
            dedent(
                """\
                };

                const int _zip_err_str_count = sizeof(_zip_err_str)/sizeof(_zip_err_str[0]);

                const struct _zip_err_info _zip_err_details[] = {
                """
            )
        )

        # From cmake/GenerateZipErrorStrings.cmake:
        #
        # foreach(errln ${zipint_h_err})
        #   string(REGEX MATCH "#define ZIP_ER_DETAIL_([A-Z0-9_]+) ([0-9]+)[ \t]+/([-*0-9a-zA-Z, ']*)/" err_t_tt ${errln})
        #   string(REGEX MATCH "([E|G]+) ([-0-9a-zA-Z, ']*)" err_t_tt "${CMAKE_MATCH_3}")
        #   string(STRIP "${CMAKE_MATCH_2}" err_t_tt)
        #   string(APPEND zip_err_str "    { ${CMAKE_MATCH_1}, \"${err_t_tt}\" },\n")
        # endforeach()
        for line in (include_dir / "zipint.h").read_text().splitlines():
            match = re.match(
                r"#define ZIP_ER_DETAIL_([A-Z0-9_]+) ([0-9]+)[ \t]+/([-*0-9a-zA-Z, ']*)/", line
            )
            if not match:
                continue
            match = re.search(r"([EG]+) ([-0-9a-zA-Z, ']*)", match.group(3))
            if not match:
                continue
            CMAKE_MATCH_1 = match.group(1)
            err_t_tt = match.group(2).strip()
            fp.write(f'    {{ {CMAKE_MATCH_1}, "{err_t_tt}" }},\n')

        fp.write(
            dedent(
                """\
                };

                const int _zip_err_details_count = sizeof(_zip_err_details)/sizeof(_zip_err_details[0]);
                """
            )
        )


if __name__ == "__main__":
    sys.exit(main())
