# VEAF-Open-Training-Mission

All scripts, libraries and documentation needed to build the VEAF Open Training Mission

## How to work on this mission ?

requirements: 

* DCS World 2.5+
* 7za.exe in your path [get 7zip Extra here](https://www.7-zip.org/download.html)
* git
* the VEAF_mission_library git repository checked out somewhere
* an IDE (notepad++, visual studio code...)

## Prepare your environment

By default the mission is generated in the build folder, using a pattern that adds the current date in ISO format to the prefix *OT_Causacus_*  
If you want to override the default, simply set the *MISSION_FILE* variable to something else  
Example :  

```
# set MISSION_FILE="c:\users\bozo\Saved Games\DCS\missions\VEAF_OT.miz"
```

## Mission editor workflow

Never make changes in scripts and in mission editor at the same time.
Always use this defined process:

![editor_workflow](docs/editor_workflow.png)

## Mission maker tips

* [QRA missions](doc/missionMaker/qra.md)

### Extracting data from an edited mission

Let's say you opened the OpenTraining mission in the editor and changed some things (e.g. added a few planes and waypoints).  
You need to extract the content of the .miz file into the *src* folder, in order to push it to Github.  
Simply copy your edited mission file to the *VEAF-Open-Training-Mission* folder and rename it to *to-extract.miz* ; then run the *extract* command.  

### Compile the mission from source

When you need to test or deploy the mission from source, you need to build it.  
Fortunately it's very easy : simply open a command prompt in the *VEAF-Open-Training-Mission* folder and run the *build* command.  
It will compile the mission file and tell you where it is stored.

```
# build                                        
MISSION_FILE = .\build\OT_Causacus_20182708.miz
Built .\build\OT_Causacus_20182708.miz         
```