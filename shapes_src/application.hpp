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

#ifndef APPLICATION_HPP
#define APPLICATION_HPP

#include <iostream>
#include <csignal>
#include <dds/core/ddscore.hpp>

namespace application {

    // Catch control-C and tell application to shut down
    bool shutdown_requested = false;

    inline void stop_handler(int)
    {
        shutdown_requested = true;
        std::cout << "preparing to shut down..." << std::endl;
    }

    inline void setup_signal_handlers()
    {
        signal(SIGINT, stop_handler);
        signal(SIGTERM, stop_handler);
    }

    enum class ParseReturn {
        ok,
        failure,
        exit
    };

    struct ApplicationArguments {
        ParseReturn parse_result;
        unsigned int domain_id;
        unsigned int sample_count;
        rti::config::Verbosity verbosity;
        std::string color;
        bool use_cds;
        bool use_macvlan;
        std::string qos_profile;

        ApplicationArguments(
            ParseReturn parse_result_param,
            unsigned int domain_id_param,
            unsigned int sample_count_param,
            rti::config::Verbosity verbosity_param,
            const std::string& color_param = "GREEN",
            bool use_cds_param = false,
            bool use_macvlan_param = false,
            const std::string& qos_profile_param = "")
            : parse_result(parse_result_param),
            domain_id(domain_id_param),
            sample_count(sample_count_param),
            verbosity(verbosity_param),
            color(color_param),
            use_cds(use_cds_param),
            use_macvlan(use_macvlan_param),
            qos_profile(qos_profile_param) {}
    };

    inline void set_verbosity(
        rti::config::Verbosity& verbosity,
        int verbosity_value)
    {
        switch (verbosity_value) {
            case 0:
            verbosity = rti::config::Verbosity::SILENT;
            break;
            case 1:
            verbosity = rti::config::Verbosity::EXCEPTION;
            break;
            case 2:
            verbosity = rti::config::Verbosity::WARNING;
            break;
            case 3:
            verbosity = rti::config::Verbosity::STATUS_ALL;
            break;
            default:
            verbosity = rti::config::Verbosity::EXCEPTION;
            break;
        }
    }

    // Parses application arguments for example.
    inline ApplicationArguments parse_arguments(int argc, char *argv[])
    {
        int arg_processing = 1;
        bool show_usage = false;
        ParseReturn parse_result = ParseReturn::ok;
        unsigned int domain_id = 0;
        unsigned int sample_count = (std::numeric_limits<unsigned int>::max)();
        rti::config::Verbosity verbosity(rti::config::Verbosity::EXCEPTION);
        std::string color = "GREEN";
        bool use_cds = false;
        bool use_macvlan = false;
        std::string qos_profile;

        while (arg_processing < argc) {
            if ((argc > arg_processing + 1) 
            && (strcmp(argv[arg_processing], "-d") == 0
            || strcmp(argv[arg_processing], "--domain") == 0)) {
                domain_id = atoi(argv[arg_processing + 1]);
                arg_processing += 2;
            } else if ((argc > arg_processing + 1)
            && (strcmp(argv[arg_processing], "-s") == 0
            || strcmp(argv[arg_processing], "--sample-count") == 0)) {
                sample_count = atoi(argv[arg_processing + 1]);
                arg_processing += 2;
            } else if ((argc > arg_processing + 1)
            && (strcmp(argv[arg_processing], "-v") == 0
            || strcmp(argv[arg_processing], "--verbosity") == 0)) {
                set_verbosity(verbosity, atoi(argv[arg_processing + 1]));
                arg_processing += 2;
            } else if ((argc > arg_processing + 1)
            && (strcmp(argv[arg_processing], "-c") == 0
            || strcmp(argv[arg_processing], "--color") == 0)) {
                color = argv[arg_processing + 1];
                arg_processing += 2;
            } else if (strcmp(argv[arg_processing], "--cds") == 0) {
                use_cds = true;
                arg_processing += 1;
            } else if (strcmp(argv[arg_processing], "--macvlan") == 0) {
                use_macvlan = true;
                arg_processing += 1;
            } else if ((argc > arg_processing + 1)
            && (strcmp(argv[arg_processing], "--qos-profile") == 0)) {
                qos_profile = argv[arg_processing + 1];
                arg_processing += 2;
            } else if (strcmp(argv[arg_processing], "-h") == 0
            || strcmp(argv[arg_processing], "--help") == 0) {
                std::cout << "Example application." << std::endl;
                show_usage = true;
                parse_result = ParseReturn::exit;
                break;
            } else {
                std::cout << "Bad parameter." << std::endl;
                show_usage = true;
                parse_result = ParseReturn::failure;
                break;
            }
        }
        if (show_usage) {
            std::cout << "Usage:\n"\
            "    -d, --domain       <int>   Domain ID this application will\n" \
            "                               subscribe in.  \n"
            "                               Default: 0\n"\
            "    -s, --sample_count <int>   Number of samples to receive before\n"\
            "                               cleanly shutting down. \n"
            "                               Default: infinite\n"
            "    -v, --verbosity    <int>   How much debugging output to show.\n"\
            "                               Range: 0-3 \n"
            "                               Default: 1\n"
            "    -c, --color        <str>   Shape color to publish.\n"\
            "                               Default: GREEN\n"
            "    --cds                      Use Cloud Discovery Service profile.\n"\
            "                               Default: false\n"
            "    --macvlan                  Use Macvlan profile.\n"\
            "                               Default: false\n"
            "    --qos-profile  <str>       Use an explicit QoS profile name.\n"\
            "                               Example: ShapeType_Library::ShapeType_Profile"
            << std::endl;
        }

        return ApplicationArguments(
            parse_result,
            domain_id,
            sample_count,
            verbosity,
            color,
            use_cds,
            use_macvlan,
            qos_profile);
    }

}  // namespace application

#endif  // APPLICATION_HPP
