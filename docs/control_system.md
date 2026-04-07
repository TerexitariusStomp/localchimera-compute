Wikipedia The Free Encyclopedia

    Donate
    Create account
    Log in

Contents

    (Top)
    Open-loop and closed-loop control
    Feedback control systems
    Logic control
    On–off control
    Linear control
    Fuzzy logic
    Physical implementation
    See also
    References
    External links

Control system

    Article
    Talk

    Read
    Edit
    View history

Tools

Appearance
Birthday mode (Baby Globe)

    Disabled
    Enabled
    Learn more about Birthday mode

Text

    Small
    Standard
    Large

Width

    Standard
    Wide

Color (beta)

    Automatic
    Light
    Dark

From Wikipedia, the free encyclopedia
For other uses, see Control system (disambiguation).
icon
This article needs additional citations for verification. Please help improve this article by adding citations to reliable sources in this article. Unsourced material may be challenged and removed.
Find sources: "Control system" – news · newspapers · books · scholar · JSTOR (December 2010) (Learn how and when to remove this message)
The centrifugal governor is an early proportional control mechanism.

A control system manages, commands, directs, or regulates the behavior of other devices or systems using control loops. It can range from a single home heating controller using a thermostat controlling a domestic boiler to large industrial control systems which are used for controlling processes or machines. The control systems are designed via control engineering process.

For continuously modulated control, a feedback controller is used to automatically control a process or operation. The control system compares the value or status of the process variable (PV) being controlled with the desired value or setpoint (SP), and applies the difference as a control signal to bring the process variable output of the plant to the same value as the setpoint.

For sequential and combinational logic, software logic, such as in a programmable logic controller, is used.[clarification needed]
Open-loop and closed-loop control
This section is an excerpt from Control loop § Open-loop and closed-loop.[edit]

Fundamentally, there are two types of control loop: open-loop control (feedforward), and closed-loop control (feedback).

    In open-loop control, the control action from the controller is independent of the "process output" (or "controlled process variable"). A good example of this is a central heating boiler controlled only by a timer, so that heat is applied for a constant time, regardless of the temperature of the building. The control action is the switching on/off of the boiler, but the controlled variable should be the building temperature, but is not because this is open-loop control of the boiler, which does not give closed-loop control of the temperature.
    In closed loop control, the control action from the controller is dependent on the process output. In the case of the boiler analogy, this would include a thermostat to monitor the building temperature, and thereby feed back a signal to ensure the controller maintains the building at the temperature set on the thermostat. A closed loop controller therefore has a feedback loop which ensures the controller exerts a control action to give a process output the same as the "reference input" or "set point". For this reason, closed loop controllers are also called feedback controllers.[1]

The definition of a closed loop control system according to the British Standards Institution is "a control system possessing monitoring feedback, the deviation signal formed as a result of this feedback being used to control the action of a final control element in such a way as to tend to reduce the deviation to zero."[2]

Likewise; "A Feedback Control System is a system which tends to maintain a prescribed relationship of one system variable to another by comparing functions of these variables and using the difference as a means of control."[2]
Feedback control systems
This section is an excerpt from Closed-loop controller.[edit]
Example of a single industrial control loop; showing continuously modulated control of process flow.
Illustration of a Closed Loop Control consisting of Set Point w ( t ) {\displaystyle w(t)}, Measured Output y m ( t ) {\displaystyle y*{m}(t)}, Measured Error e ( t ) {\displaystyle e(t)}, Controller Output u ( t ) {\displaystyle u(t)}, System Input u s ( t ) {\displaystyle u*{s}(t)}, Disturbance d ( t ) {\displaystyle d(t)}, and System Output y ( t ) {\displaystyle y(t)}

A closed-loop controller or feedback controller is a control loop which incorporates feedback, in contrast to an open-loop controller or non-feedback controller. A closed-loop controller uses feedback to control states or outputs of a dynamical system. Its name comes from the information path in the system: process inputs (e.g., voltage applied to an electric motor) have an effect on the process outputs (e.g., speed or torque of the motor), which is measured with sensors and processed by the controller; the result (the control signal) is "fed back" as input to the process, closing the loop.[3]

In the case of linear feedback systems, a control loop including sensors, control algorithms, and actuators is arranged in an attempt to regulate a variable at a setpoint (SP). An everyday example is the cruise control on a road vehicle; where external influences such as hills would cause speed changes, and the driver has the ability to alter the desired set speed. The PID algorithm in the controller restores the actual speed to the desired speed in an optimum way, with minimal delay or overshoot, by controlling the power output of the vehicle's engine. Control systems that include some sensing of the results they are trying to achieve are making use of feedback and can adapt to varying circumstances to some extent. Open-loop control systems do not make use of feedback, and run only in pre-arranged ways.

Closed-loop controllers have the following advantages over open-loop controllers:

    disturbance rejection (such as hills in the cruise control example above)
    guaranteed performance even with model uncertainties, when the model structure does not match perfectly the real process and the model parameters are not exact
    unstable processes can be stabilized
    reduced sensitivity to parameter variations
    improved reference tracking performance
    improved rectification of random fluctuations[4]

In some systems, closed-loop and open-loop control are used simultaneously. In such systems, the open-loop control is termed feedforward and serves to further improve reference tracking performance.

A common closed-loop controller architecture is the PID controller.
A basic feedback loop
Logic control

Logic control systems for industrial and commercial machinery were historically implemented by interconnected electrical relays and cam timers using ladder logic. Today, most such systems are constructed with microcontrollers or more specialized programmable logic controllers (PLCs). The notation of ladder logic is still in use as a programming method for PLCs.[5]

Logic controllers may respond to switches and sensors and can cause the machinery to start and stop various operations through the use of actuators. Logic controllers are used to sequence mechanical operations in many applications. Examples include elevators, washing machines and other systems with interrelated operations. An automatic sequential control system may trigger a series of mechanical actuators in the correct sequence to perform a task. For example, various electric and pneumatic transducers may fold and glue a cardboard box, fill it with the product and then seal it in an automatic packaging machine.

PLC software can be written in many different ways – ladder diagrams, SFC (sequential function charts) or statement lists.[6]
On–off control
Main article: Bang–bang control

On–off control uses a feedback controller that switches abruptly between two states. A simple bi-metallic domestic thermostat can be described as an on-off controller. When the temperature in the room (PV) goes below the user setting (SP), the heater is switched on. Another example is a pressure switch on an air compressor. When the pressure (PV) drops below the setpoint (SP) the compressor is powered. Refrigerators and vacuum pumps contain similar mechanisms. Simple on–off control systems like these can be cheap and effective.
Linear control
This section is an excerpt from Linear control.[edit]

Linear control are control systems and control theory based on negative feedback for producing a control signal to maintain the controlled process variable (PV) at the desired setpoint (SP). There are several types of linear control systems with different capabilities.
Fuzzy logic
Main article: Fuzzy logic

Fuzzy logic is an attempt to apply the easy design of logic controllers to the control of complex continuously varying systems. Basically, a measurement in a fuzzy logic system can be partly true.

The rules of the system are written in natural language and translated into fuzzy logic. For example, the design for a furnace would start with: "If the temperature is too high, reduce the fuel to the furnace. If the temperature is too low, increase the fuel to the furnace."

Measurements from the real world (such as the temperature of a furnace) are fuzzified and logic is calculated arithmetic, as opposed to Boolean logic, and the outputs are de-fuzzified to control equipment.

When a robust fuzzy design is reduced to a single, quick calculation, it begins to resemble a conventional feedback loop solution and it might appear that the fuzzy design was unnecessary. However, the fuzzy logic paradigm may provide scalability for large control systems where conventional methods become unwieldy or costly to derive.[citation needed]

Fuzzy electronics is an electronic technology that uses fuzzy logic instead of the two-value logic more commonly used in digital electronics.
Physical implementation
A DCS control room where large screens display plant information. The operators can view and control any part of the process from their computer screens, whilst retaining a plant overview on the larger screens.
A control panel of a hydraulic heat press machine

The range of control system implementation is from compact controllers often with dedicated software for a particular machine or device, to distributed control systems for industrial process control for a large physical plant.

Logic systems and feedback controllers are usually implemented with programmable logic controllers. The Broadly Reconfigurable and Expandable Automation Device (BREAD) is a recent framework that provides many open-source hardware devices which can be connected to create more complex data acquisition and control systems.[7]
See also

    Building automation – Branch of automation
    Coefficient diagram method
    Control theory – Branch of engineering and mathematics
    Cybernetics – Transdisciplinary field concerned with regulatory and purposive systems
    Distributed control system – Computerized control systems with distributed decision-making
    Droop speed control – Control mode for AC power generators
    Education and training of electrical and electronics engineers
    EPICS – Software infrastructure for building distributed control systems
    Good regulator – Theorem in cybernetics
    Guidance, navigation, and control – Branch of engineering
    Hierarchical control system – Layered model for component organization in software and robotics
    HVAC control system – Control system for heating, ventilation, and air conditioning equipment
    Industrial control system – Process control systems and associated instrumentation
    Motion control – Field of automation which studies how to precisely move parts of machines
    Networked control system
    Numerical control – Computer control of machine tools
    Perceptual control theory – Psychological theory
    PID controller – Control loop feedback mechanism
    Process control – Discipline that uses industrial control to achieve a production level of consistency
    Process optimization – Series of actions for bettering effective usage
    Programmable logic controller – Programmable digital computer used to control machinery
    Real-time computing – Study of hardware and software systems that have a "real-time constraint"
    Sampled data system
    SCADA – Control system architecture for supervision of machines and processes
    VisSim – Software for simulation of dynamic systems

References

    "Feedback and control systems" - JJ Di Steffano, AR Stubberud, IJ Williams. Schaums outline series, McGraw-Hill 1967
    Mayr, Otto (1970). The Origins of Feedback Control. Clinton, MA US: The Colonial Press, Inc.
    Bechhoefer, John (2005-08-31). "Feedback for physicists: A tutorial essay on control". Reviews of Modern Physics. 77 (3): 783–836. doi:10.1103/RevModPhys.77.783.
    Cao, F. J.; Feito, M. (2009-04-10). "Thermodynamics of feedback controlled systems". Physical Review E. 79 (4) 041118. arXiv:0805.4824. doi:10.1103/PhysRevE.79.041118.
    Kuphaldt, Tony R. "Chapter 6 LADDER LOGIC". Lessons In Electric Circuits -- Volume IV. Archived from the original on 12 September 2010. Retrieved 22 September 2010.
    Brady, Ian. "Programmable logic controllers - benefits and applications" (PDF). PLCs. Archived (PDF) from the original on 2 February 2014. Retrieved 5 December 2011.
    Hafting, Finn K.; Kulas, Daniel; Michels, Etienne; Chipkar, Sarvada; Wisniewski, Stefan; Shonnard, David; Pearce, Joshua M. (2023-12-05). "Modular Open-Source Design of Pyrolysis Reactor Monitoring and Control Electronics". Electronics. 12 (24): 4893. doi:10.3390/electronics12244893. ISSN 2079-9292.

External links
Wikibooks logo
Wikibooks has a book on the topic of: Control Systems

    SystemControl Create, simulate or HWIL control loops with Python. Includes Kalman filter, LQG control among others.
    Semiautonomous Flight Direction - Reference unmannedaircraft.org
    Control System Toolbox for design and analysis of control systems.
    Control Systems Manufacturer Design and Manufacture of control systems.
    Mathematica functions for the analysis, design, and simulation of control systems
    Python Control System (PyConSys) Create and simulate control loops with Python. AI for setting PID parameters.

    vte

Electronics

Authority control databases Edit this at Wikidata

Categories:

    Control theoryControl engineeringSystems engineeringSystems theoryAutomation

    This page was last edited on 3 September 2025, at 12:58 (UTC).
    Text is available under the Creative Commons Attribution-ShareAlike 4.0 License; additional terms may apply. By using this site, you agree to the Terms of Use and Privacy Policy. Wikipedia® is a registered trademark of the Wikimedia Foundation, Inc., a non-profit organization.

    Privacy policy
    About Wikipedia
    Disclaimers
    Contact Wikipedia
    Legal & safety contacts
    Code of Conduct
    Developers
    Statistics
    Cookie statement
    Mobile view

    Wikimedia Foundation
    Powered by MediaWiki
