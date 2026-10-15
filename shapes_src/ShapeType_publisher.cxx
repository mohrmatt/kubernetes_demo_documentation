/*
* (c) Copyright, Real-Time Innovations, 2020.  All rights reserved.
* RTI grants Licensee a license to use, modify, compile, and create derivative
* works of the software solely for use with RTI Connext DDS. Licensee may
* redistribute copies of the software provided that all such copies are subject
* to this license. The software is provided "as is", with no warranty of any
* type, including any warranty for fitness for any purpose. RTI is under no
* obligation to maintain or support the software. RTI shall not be liable for
* any incidental or consequential damages arising out of the use or inability
* to use the software.
*/

#include <iostream>
#include <random>

#include <dds/pub/ddspub.hpp>
#include <rti/util/util.hpp>      // for sleep()
#include <rti/config/Logger.hpp>  // for logging
// alternatively, to include all the standard APIs:
//  <dds/dds.hpp>
// or to include both the standard APIs and extensions:
//  <rti/rti.hpp>
//
// For more information about the headers and namespaces, see:
//    https://community.rti.com/static/documentation/connext-dds/7.3.0/doc/api/connext_dds/api_cpp2/group__DDSNamespaceModule.html
// For information on how to use extensions, see:
//    https://community.rti.com/static/documentation/connext-dds/7.3.0/doc/api/connext_dds/api_cpp2/group__DDSCpp2Conventions.html

#include "application.hpp"  // for command line parsing and ctrl-c
#include "ShapeType.hpp"

void run_publisher_application(
    unsigned int domain_id,
    unsigned int sample_count,
    const std::string& color,
    bool use_cds,
    bool use_macvlan,
    const std::string& qos_profile_override)
{
    // DDS objects behave like shared pointers or value types
    // (see https://community.rti.com/best-practices/use-modern-c-types-correctly)

    // Determine which QoS profile to use
    std::string qos_profile = "ShapeType_Library::ShapeType_Profile";
    if (!qos_profile_override.empty()) {
        qos_profile = qos_profile_override;
    } else if (use_macvlan) {
        qos_profile = "ShapeType_Library::ShapeType_Macvlan_Profile";
    } else if (use_cds) {
        qos_profile = "ShapeType_Library::ShapeType_CloudDiscovery_Profile";
    }
    
    std::cout << "Using QoS profile: " << qos_profile << std::endl;

    // Start communicating in a domain, usually one participant per application
    dds::domain::qos::DomainParticipantQos participant_qos = 
        dds::core::QosProvider::Default().participant_qos(qos_profile);
    dds::domain::DomainParticipant participant(domain_id, participant_qos);

    // Create a Topic with a name and a datatype
    dds::topic::Topic< ::ShapeTypeExtended> topic(participant, "Square");

    // Create a Publisher
    dds::pub::Publisher publisher(participant);

    // Create a DataWriter with default QoS
    dds::pub::DataWriter< ::ShapeTypeExtended> writer(publisher, topic);

    // Set up random number generation
    std::random_device rd;
    std::mt19937 gen(rd());
    std::uniform_int_distribution<> dis(0, 254);

    ::ShapeTypeExtended data;
    // Initialize fixed values
    data.color(color);
    data.shapesize(30);
    
    // Main loop, write data
    for (unsigned int samples_written = 0;
    !application::shutdown_requested && samples_written < sample_count;
    samples_written++) {
        // Set random x and y coordinates (0-254)
        data.x(dis(gen));
        data.y(dis(gen));
        
        // Modify the data to be written here
        std::cout << "Writing ::ShapeTypeExtended, count " << samples_written 
                  << " (x=" << data.x() << ", y=" << data.y() 
                  << ", color=" << data.color() << ", size=" << data.shapesize() << ")" << std::endl;

        writer.write(data);

        // Send once every second
        rti::util::sleep(dds::core::Duration(1));
    }
}

int main(int argc, char *argv[])
{

    using namespace application;

    // Parse arguments and handle control-C
    auto arguments = parse_arguments(argc, argv);
    if (arguments.parse_result == ParseReturn::exit) {
        return EXIT_SUCCESS;
    } else if (arguments.parse_result == ParseReturn::failure) {
        return EXIT_FAILURE;
    }
    setup_signal_handlers();

    // Sets Connext verbosity to help debugging
    rti::config::Logger::instance().verbosity(arguments.verbosity);

    try {
        run_publisher_application(
            arguments.domain_id,
            arguments.sample_count,
            arguments.color,
            arguments.use_cds,
            arguments.use_macvlan,
            arguments.qos_profile);
    } catch (const std::exception& ex) {
        // This will catch DDS exceptions
        std::cerr << "Exception in run_publisher_application(): " << ex.what()
        << std::endl;
        return EXIT_FAILURE;
    }

    // Releases the memory used by the participant factory.  Optional at
    // application exit
    dds::domain::DomainParticipant::finalize_participant_factory();

    return EXIT_SUCCESS;
}
