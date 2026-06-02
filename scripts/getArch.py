#!/usr/bin/env python3

import sys
import tarfile
import subprocess
import psycopg2

archMap = {"MIPS64":"mips64", "MIPS":"mips", "ARM aarch64":"aarch64", "ARM64":"aarch64", "ARM":"arm", "Intel 80386":"intel", "x86-64":"intel64", "PowerPC":"ppc", "unknown":"unknown"}

endMap = {"LSB":"el", "MSB":"eb"}

def getArch(filetype):
    for arch in archMap:
        if filetype.find(arch) != -1:
            return archMap[arch]
    return None

def getEndian(filetype):
    for endian in endMap:
        if filetype.find(endian) != -1:
            return endMap[endian]
    return None

infile = sys.argv[1]
psql_ip = sys.argv[2]
base = infile[infile.rfind("/") + 1:]
iid = base[:base.find(".")]

tar = tarfile.open(infile, 'r')

infos = []
fileList = []
for info in tar.getmembers():
    if any([info.name.find(binary) != -1 for binary in ["/busybox", "/alphapd", "/boa", "/http", "/hydra", "/helia", "/webs"]]):
        infos.append(info)
    elif any([info.name.find(path) != -1 for path in ["/sbin/", "/bin/"]]):
        infos.append(info)
    fileList.append(info.name)

with open("scratch/" + iid + "/fileList", "w") as f:
    for filename in fileList:
        try:
            f.write(filename + "\n")
        except:
            continue

for info in infos:
    tar.extract(info, path="/tmp/" + iid)
    filepath = "/tmp/" + iid + "/" + info.name
    filetype = subprocess.check_output(["file", filepath]).decode()

    arch = getArch(filetype)
    endian = getEndian(filetype)
    if arch and endian:
        # AARCH64 is always little-endian, don't append endian suffix
        if arch == "aarch64":
            arch_str = arch
        elif arch == "arm" and endian == "el" and "hard-float" in filetype:
            arch_str = "armhf"
        else:
            arch_str = arch + endian

        print(arch_str)
        subprocess.call(["rm", "-rf", "/tmp/" + iid])
        dbh = psycopg2.connect(database="firmware",
                               user="firmadyne",
                               password="firmadyne",
                               host=psql_ip)
        cur = dbh.cursor()
        query = """UPDATE image SET arch = '%s' WHERE id = %s;"""
        cur.execute(query % (arch_str, iid))
        dbh.commit()

        with open("scratch/" + iid + "/fileType", "w") as f:
            f.write(filetype)

        break

subprocess.call(["rm", "-rf", "/tmp/" + iid])
