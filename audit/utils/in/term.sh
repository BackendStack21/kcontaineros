# Inside the container, with stdin, stdout and stderr on a terminal.
# Every case prints "### name" and then lets one kcontaineros utility print
# something that contains hostile bytes: ESC, BEL, 0x01, 0xff, 0x9b (C1 CSI),
# CR, TAB and a newline. The host side fails any case whose output holds a
# byte outside printable ASCII, apart from the final newline of each line.
B=/bb/busybox
H=$($B printf 'E\033[31mR\007\001\377\233\rX\tY')
HN=$($B printf 'E\033[31mR\007\001\377\233\rX\tY\nZ')     # the same with a newline in it
L255=$($B printf '\033%.0s' 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31 32 33 34 35 36 37 38 39 40 41 42 43 44 45 46 47 48 49 50 51 52 53 54 55 56 57 58 59 60 61 62 63 64 65 66 67 68 69 70 71 72 73 74 75 76 77 78 79 80 81 82 83 84 85 86 87 88 89 90 91 92 93 94 95 96 97 98 99 100 101 102 103 104 105 106 107 108 109 110 111 112 113 114 115 116 117 118 119 120 121 122 123 124 125 126 127 128 129 130 131 132 133 134 135 136 137 138 139 140 141 142 143 144 145 146 147 148 149 150 151 152 153 154 155 156 157 158 159 160 161 162 163 164 165 166 167 168 169 170 171 172 173 174 175 176 177 178 179 180 181 182 183 184 185 186 187 188 189 190 191 192 193 194 195 196 197 198 199 200 201 202 203 204 205 206 207 208 209 210 211 212 213 214 215 216 217 218 219 220 221 222 223 224 225 226 227 228 229 230 231 232 233 234 235 236 237 238 239 240 241 242 243 244 245 246 247 248 249 250)
cd /tmp; $B mkdir t; cd t
echo x > "$H"; echo x > "$HN"; $B ln -s "$HN" "l$H"; $B mkdir "d$HN" "d$HN/sub"; echo x > "d$HN/f$H"; echo x > "$L255"; echo plain > a
n() { echo; echo "### $*"; }
n ls;            /bin/ls
n ls -la;        /bin/ls -la
n ls file;       /bin/ls "$HN"
n ls -l file;    /bin/ls -l "$HN" "l$H"
n ls headers;    /bin/ls "d$HN" "d$HN/sub"
n ls -l dir;     /bin/ls -l "d$HN"
n ls missing;    /bin/ls "no$HN"
n ls option;     /bin/ls "-$H"
n ls long;       /bin/ls -l "$L255" "$L255/x"
n pwd;           (cd "d$HN" && /bin/pwd)
n pwd arg;       /bin/pwd "$HN"
/bb/h comm "$H" 4 &
/bb/h argv /bb/h "$HN" sleep 4 "$H" &
$B sleep 0.3
n ps;            /bin/ps
n ps arg;        /bin/ps "$HN"
n cat missing;   /bin/cat "no$HN"
n cat dir;       /bin/cat "d$HN"
n chmod missing; /bin/chmod 644 "no$HN"
n chmod mode;    /bin/chmod "$HN" a
n chmod option;  /bin/chmod "-$HN" a
n chown missing; /bin/chown 0 "no$HN"
n chown owner;   /bin/chown "$HN" a
n cp missing;    /bin/cp "no$HN" x
n cp dest;       /bin/cp a "no$HN/x"
n cp same;       /bin/cp "$HN" "$HN"
n cp notdir;     /bin/cp a a "$HN"
n mv missing;    /bin/mv "no$HN" x
n mv dest;       /bin/mv a "no$HN/x"
n ln missing;    /bin/ln "no$HN" x
n ln exists;     /bin/ln -s a "$HN"
n mkdir exists;  /bin/mkdir "d$HN"
n mkdir -p;      /bin/mkdir -p "$HN/x"
n rm missing;    /bin/rm "no$HN"
n rm dir;        /bin/rm "d$HN"
n rm refuse;     /bin/rm -r "d$HN/."
n rm -r deep;    /bin/rm -r "d$HN/sub/no$H"
n touch;         /bin/touch "no$HN/x"
n sleep;         /bin/sleep "$HN"
n kill pid;      /bin/kill "$HN"
n kill sig;      /bin/kill "-$HN" 1
n kill -s;       /bin/kill -s "$HN" 1
n env option;    /bin/env "-$HN"
n env command;   /bin/env "no$HN"
n uname;         /bin/uname "-$HN"
n applet;        /bin/kcontaineros "$HN"
n argv0;         /bb/h argv /bin/kcontaineros "$HN"
n argv0 path;    /bb/h argv /bin/kcontaineros "/x/$HN" a
n env print;     /bin/env -i "V=$H" /bin/env
n env name;      /bin/env -i "$HN=1"
n uname -a;      /bin/uname -a
n done
