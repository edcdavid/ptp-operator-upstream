#!/bin/bash
set -x
set -euo pipefail

modprobe -r netdevsim 
modprobe gnss
modprobe netdevsim pci_bus_nr=0x1f
modprobe openvswitch