# Branch-predictor
Implementation of TAGE branch predictor in Bluespec for I-Class SHAKTHI processors

Author:Ram Srivathsa Sankar
Mentor:Rahul Bodduna

The folder 'tage predictor' contains the .bsv and .bspec files for the predictor while the 'Testbench' folder contains the .bsv file for the testbench, the .bin files to initialize the predictor banks and the .dump files for testing the Dhrystone benchmark.
The 'verilog' folder contains the verilog files that can be used for analyzing the effectiveness of the design on Vivado whhile the 'vivado' folder contains the Vivado project file.

The branch predictor has been implemented according to the exact same specifications as is given in the reference research paper by Michaud.
