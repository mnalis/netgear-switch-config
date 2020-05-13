# netgear-switch-config
automatic VLAN configuration tool for Netgear GS724T series (and similar) smart LAN switches

Automatically configure your switch without clicking on web interface, and keeps your switch VLAN config as documentation in your git!

Requires perl and Expect and Set::IntSpan perl modules (`apt-get install libexpect-perl libset-intspan-perl` on Debian)

* example.cfg - annotated example configuration file
* netgear_interfaces.pl - main script, configures switch as specified in config file
  usage: `netgear_interfaces.pl configure example.cfg`
  Also supports following environment variables, see the script for details: `NUKEALL`, `DRYRUN`, `DEBUG`
* netgear_vlan - send commands to your switch, requires TCL /usr/bin/expect utility (`apt-get install tcl-expect` on Debian)
  usage: `netgear_vlan save` to write switch changes to NVRAM after running `netgear_interfaces.pl`, so changes will persist after switch reboot! 
  or `netgear_vlan show` to show current configuration... Also allows other commands.
* parseconfig.pl - parses `example.cfg` config file (for debug)

Before using for first time, you will need to edit the scripts at the top, and change IP, port, username, password to values matching your switch. 
