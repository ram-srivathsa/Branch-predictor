# Branch-predictor
Implementation of TAGE branch predictor in Bluespec for I-Class SHAKTHI processors

Author:Ram Srivathsa Sankar

Mentor:Rahul Bodduna

The folder 'tage predictor' contains the .bsv and .bspec files for the predictor while the 'Testbench' folder contains the .bsv file for the testbench, the .bin files to initialize the predictor banks and the .dump files for testing the Dhrystone benchmark.

The 'verilog' folder contains the verilog files that can be used for analyzing the effectiveness of the design on Vivado while the 'vivado' folder contains the Vivado project file as well as the syn_area.txt and syn_timing.txt files that provide the utilization and timing reports respectively.

The branch predictor has been implemented according to the exact same specifications as is given in the reference research paper by Michaud.

Results: 

On testing the predictor with the Dhrystone benchmark, 110 misprediction were reported out of a total of 58,800 branches which corresponds to a prediction accuracy of 99.8%. For the first 1000 branches, 18  mispredictions occurred which corresponds to an accuracy of 98.2%.

In Vivado, the maximum operating frequency of the design was found to be 309MHz on an Artix 7 board while the utilization report may be found in the 'vivado' folder.

